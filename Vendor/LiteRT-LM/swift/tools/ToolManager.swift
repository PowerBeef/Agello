// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified by Patrice Déry for Agello (PowerBeef/agello-litert-lm, branch main):
// the tool registry declared for Swift 6 language mode, and tool results/arguments
// validated for JSONSerialization (non-finite floats stringified before encoding).

import Foundation

/// Manages the discovery, schema generation, and execution of tools.
public final class ToolManager: Sendable {

  /// A map of tool names to their corresponding Swift Types.
  /// We store the `Type` so we can instantiate new copies via Codable.
  /// Never changed after init (Agello: declared for Swift 6 language mode, 2026-11-16).
  nonisolated(unsafe) private let toolRegistry: [String: Tool.Type]

  /// The JSON schema string representing all registered tools.
  /// This is computed once during initialization.
  public let toolsJsonDescription: String

  /// Initializes the ToolManager with a list of tool instances.
  ///
  /// - Parameter tools: A list of instantiated tools (e.g. `[GetWeatherTool()]`).
  ///   These instances are used *only* for schema generation. Execution uses new instances.
  public init(tools: [Tool]) {
    var registry: [String: Tool.Type] = [:]
    var schemaList: [[String: Any]] = []
    let useSnakeCase = ExperimentalFlags.convertCamelToSnakeCaseInToolDescription

    for tool in tools {
      let name = type(of: tool).name
      let toolNameInModel = useSnakeCase ? name.camelToSnakeCase() : name
      registry[toolNameInModel] = type(of: tool)

      // Use the provided instance to generate the schema via Mirror
      schemaList.append(tool.getSchema())
    }

    self.toolRegistry = registry

    // Serialize the schema list to a JSON string
    if let data = try? JSONSerialization.data(withJSONObject: schemaList, options: []),
      let jsonString = String(data: data, encoding: .utf8)
    {
      self.toolsJsonDescription = jsonString
    } else {
      self.toolsJsonDescription = "[]"
    }
  }

  /// Whether the registered tool named `name` declares itself read-only and safe for
  /// concurrent execution within a single tool round.
  public func isReadOnly(name: String) -> Bool {
    toolRegistry[name]?.isReadOnly ?? false
  }

  /// Executes a tool based on the name and JSON arguments provided by the model.
  ///
  /// - Parameters:
  ///   - name: The name of the tool to execute.
  ///   - arguments: The arguments as a dictionary.
  /// - Returns: The result of the tool execution. This will be a JSON-compatible type (String, Number, Bool, Array, Dictionary).
  public func execute(name: String, arguments: [String: Any]) async throws -> Any {
    guard let ToolType = toolRegistry[name] else {
      throw LiteRTLMError.tool(.notFound(name: name))
    }

    // 1. Create a template instance to access default values.
    // This allows us to handle optional parameters that the model might omit from its output.
    // Swift Codable requires all keys to be present.
    // By manually merging defaults, we ensure decoding succeeds.
    let defaultTool = ToolType.init()
    var defaults: [String: Any] = [:]
    var expectedTypes: [String: String] = [:]

    // 2. Reflect to extract default values and expected JSON schema scalar types.
    let mirror = Mirror(reflecting: defaultTool)
    let useSnakeCase = ExperimentalFlags.convertCamelToSnakeCaseInToolDescription

    for child in mirror.children {
      guard let label = child.label else { continue }

      // Clean the property wrapper name (remove _ prefix and handle snake_case)
      let paramName = label.cleanPropertyLabel(useSnakeCase: useSnakeCase)

      if let toolParam = child.value as? ToolParamProtocol {
        if let schemaType = toolParam.getFullSchema()["type"] as? String {
          expectedTypes[paramName] = schemaType
        }
        if let defaultValue = toolParam.wrappedValueAny {
          defaults[paramName] = defaultValue
        } else if !toolParam.isRequired {
          // If it's not required (i.e. optional or has default),
          // but currently nil, we should still provide a null value
          // so the decoder doesn't fail on missing key.
          defaults[paramName] = NSNull()
        }
      }
    }

    // 3. Merge provided arguments over defaults and coerce stringified scalars (e.g. "5" -> 5).
    var mergedArgs = defaults.merging(arguments) { (_, new) in new }
    for (key, value) in mergedArgs {
      if let expectedType = expectedTypes[key] {
        mergedArgs[key] = Self.coerceArgument(value, expectedType: expectedType)
      }
    }
    guard JSONSerialization.isValidJSONObject(mergedArgs) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    let argsData = try JSONSerialization.data(withJSONObject: mergedArgs)

    let decoder = JSONDecoder()
    if useSnakeCase {
      decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // Create a new tool instance from the JSON arguments.
    // This populates the @ToolParam properties automatically.
    let toolInstance = try decoder.decode(ToolType, from: argsData)

    // Run the tool
    let result = try await toolInstance.run()

    // Normalize the result to ensure it is strictly JSON-compatible (mimicking Android logic)
    return Self.normalizeResult(result)
  }

  /// Schema-aware scalar coercion so models emitting stringified primitives (e.g. `"limit": "5"`,
  /// `"includeCompleted": "true"`, `"value": "42.5"`) still decode cleanly into Swift types.
  @_spi(Testing) public static func coerceArgument(_ value: Any, expectedType: String) -> Any {
    if value is NSNull { return value }
    switch expectedType {
    case "integer":
      if let str = value as? String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(trimmed) { return i }
        if let d = Double(trimmed), d.isFinite, d.rounded() == d,
          d >= Double(Int.min), d <= Double(Int.max)
        {
          return Int(d)
        }
      } else if let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
        let d = num.doubleValue
        if d.isFinite, d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
          return Int(d)
        }
      }
      return value
    case "number":
      if let str = value as? String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Double(trimmed), d.isFinite { return d }
      }
      return value
    case "boolean":
      if let str = value as? String {
        switch str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return value
        }
      } else if let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
        if num.intValue == 1 { return true }
        if num.intValue == 0 { return false }
      }
      return value
    case "string":
      if value is String { return value }
      if let num = value as? NSNumber {
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
          return num.boolValue ? "true" : "false"
        }
        return num.stringValue
      }
      return value
    default:
      return value
    }
  }

  /// Helper to recursively convert any result into a JSON-Serialization friendly format.
  /// - Collections: Recursively normalized.
  /// - Primitives: Passed through (non-finite floats become strings so JSONSerialization never
  ///   raises an uncatchable ObjC NSInvalidArgumentException).
  /// - Custom Objects: Converted to String.
  @_spi(Testing) public static func normalizeResult(_ value: Any) -> Any {
    if value is NSNull {
      return value
    }

    // Handle Dictionaries
    if let dict = value as? [String: Any] {
      var normalizedDict: [String: Any] = [:]
      normalizedDict.reserveCapacity(dict.count)
      for (key, val) in dict {
        normalizedDict[key] = normalizeResult(val)
      }
      return normalizedDict
    }

    // Handle Arrays
    if let array = value as? [Any] {
      return array.map { normalizeResult($0) }
    }

    let dynamicType = type(of: value)

    if dynamicType == Bool.self {
      return value
    }

    if let str = value as? String {
      return str
    }

    if dynamicType == Double.self, let d = value as? Double {
      return d.isFinite ? d : String(describing: d)
    }

    if dynamicType == Float.self, let f = value as? Float {
      return f.isFinite ? f : String(describing: f)
    }

    if dynamicType == Int.self || dynamicType == Int64.self || dynamicType == Int32.self
      || dynamicType == Int16.self || dynamicType == Int8.self || dynamicType == UInt.self
      || dynamicType == UInt64.self || dynamicType == UInt32.self || dynamicType == UInt16.self
      || dynamicType == UInt8.self
    {
      return value
    }

    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
      }
      let d = number.doubleValue
      return d.isFinite ? number : String(describing: d)
    }

    // Handle Void
    if value is Void {
      return ""
    }

    // Fallback for Custom Objects
    return String(describing: value)
  }
}
