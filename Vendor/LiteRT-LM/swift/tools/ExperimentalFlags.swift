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
// the flags are kept behind one lock (Swift 6 language mode).
import Foundation
import OSLog

/// A struct to manage flags for APIs that are not yet considered mature.
///
/// These flags guard experimental APIs that may still undergo significant changes.
/// To use any experimental flags, first call `ExperimentalFlags.optIntoExperimentalAPIs()`.
public struct ExperimentalFlags {
  /// The flags' values, behind one lock: they're set and read from any thread (Swift 6 language
  /// mode; Agello, 2026-11-16).
  private struct Values: Sendable {
    var optedIn = false
    var enableBenchmark: Bool = false
    var convertCamelToSnakeCaseInToolDescription: Bool = true
    var enableConversationConstrainedDecoding: Bool = false
    var enableConversationToolCallStreaming: Bool = false
    var conversationToolCallStreamingChannelName: String = "tool_call"
    var enableSpeculativeDecoding: Bool? = nil
    var visualTokenBudget: Int32? = nil
    var filterChannelContentFromKvCache: Bool? = nil
    var gpuEnableMetalResidencySet: Bool? = nil
    var enableYnnpack: Bool? = nil
  }

  /// The values behind an NSLock. A `Mutex` in a static returned an invalid string in optimized
  /// builds (`createConversation` crashed reading the channel name, 2026-11-16), so: a class.
  private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Values()

    func withLock<Result>(_ body: (inout Values) -> Result) -> Result {
      lock.lock()
      defer { lock.unlock() }
      return body(&values)
    }
  }

  private static let values = Store()

  /// Whether ``optIntoExperimentalAPIs()`` has been called.
  public static var optedIn: Bool { values.withLock { $0.optedIn } }

  private static let logger = Logger(
    subsystem: "com.google.odml.litertlm.swift",
    category: "ExperimentalFlags"
  )

  public static func optIntoExperimentalAPIs() {
    let first = values.withLock { values in
      defer { values.optedIn = true }
      return !values.optedIn
    }
    guard first else { return }
    logger.info("EXPERIMENTAL: LiteRTLM: Opting into experimental APIs....")
  }

  /// Sets a flag once the caller has opted in.
  private static func set<Value: Sendable>(_ flag: WritableKeyPath<Values, Value>, to value: Value) {
    let allowed = values.withLock { values in
      guard values.optedIn else { return false }
      values[keyPath: flag] = value
      return true
    }
    if !allowed { logger.error("LiteRTLM: Must opt into experimental APIs before setting this flag.") }
  }

  public static var enableBenchmark: Bool {
    get { values.withLock { $0.enableBenchmark } }
    set { set(\.enableBenchmark, to: newValue) }
  }

  /// Whether to convert the function and parameter names in to snake case for
  /// tool calling.
  ///
  /// Swift idiomatic style uses camelCase for names. However, many large
  /// language models are predominantly trained on datasets where snake_case is
  /// common.
  ///
  /// By default, this API converts Swift camelCase names to snake_case to
  /// potentially improve tool calling performance with models more familiar
  /// with snake_case.
  ///
  /// Set this flag to `false` if your model is specifically trained with
  /// camelCase tool descriptions to skip the conversion. Otherwise, the default
  /// of `true` (using snake_case) is recommended.
  ///
  /// Note: This flag is read only when a new [Conversation] is created.
  /// Changing this value will not affect any existing [Conversation] instances.
  public static var convertCamelToSnakeCaseInToolDescription: Bool {
    get { values.withLock { $0.convertCamelToSnakeCaseInToolDescription } }
    set { set(\.convertCamelToSnakeCaseInToolDescription, to: newValue) }
  }

  /// Whether to enable conversation constrained decoding. This is primarily
  /// used for function calling.
  ///
  /// Note: This flag is read only when a new [Conversation] is created.
  /// Changing this value will not affect any existing [Conversation] instances.
  public static var enableConversationConstrainedDecoding: Bool {
    get { values.withLock { $0.enableConversationConstrainedDecoding } }
    set { set(\.enableConversationConstrainedDecoding, to: newValue) }
  }

  /// Whether to enable conversation tool call streaming.
  ///
  /// Note: This flag is read only when a new [Conversation] is created.
  /// Changing this value will not affect any existing [Conversation] instances.
  public static var enableConversationToolCallStreaming: Bool {
    get { values.withLock { $0.enableConversationToolCallStreaming } }
    set { set(\.enableConversationToolCallStreaming, to: newValue) }
  }

  /// The channel name used for tool call tokens when streaming tool calls is enabled.
  public static var conversationToolCallStreamingChannelName: String {
    get { values.withLock { $0.conversationToolCallStreamingChannelName } }
    set { set(\.conversationToolCallStreamingChannelName, to: newValue) }
  }

  /// Whether to enable speculative decoding.
  ///
  /// If true, enable speculative decoding; an error will be thrown if the model does not support it.
  /// If false, disable speculative decoding.
  ///
  /// Note: This flag is read only when a new [Engine] is created. Changing this value will not
  /// affect any existing [Engine] or [Conversation] instances.
  public static var enableSpeculativeDecoding: Bool? {
    get { values.withLock { $0.enableSpeculativeDecoding } }
    set { set(\.enableSpeculativeDecoding, to: newValue) }
  }

  /// The visual token budget.
  ///
  /// The number of visual tokens that the model can generate for a single image. If null, there is
  /// no budget limit and the engine uses as much as needed.
  ///
  /// Currently, this is only supported by Gemma4. If this flag is set for a non-Gemma4 model, it
  /// will result in a no-op. The Gemma4 budget options are 70, 140, 280, 560, or 1120 tokens. See
  /// https://ai.google.dev/gemma/docs/capabilities/vision#variable-resolution for more details.
  ///
  /// Note:
  /// 1. This flag takes effect immediately and change alter the behavior of created [Conversation].
  /// 2. If the flag is set before the [Engine] is created, it determines the max visual tokens per
  ///    image for the [Engine]. For [Conversation] using the same [Engine], if the value is updated
  ///    after the [Conversation] is created, the value should not be set to a value that exceeds
  ///    the engine's max visual tokens per image.
  public static var visualTokenBudget: Int32? {
    get { values.withLock { $0.visualTokenBudget } }
    set { set(\.visualTokenBudget, to: newValue) }
  }

  /// Whether to filter channel content from the KV cache.
  public static var filterChannelContentFromKvCache: Bool? {
    get { values.withLock { $0.filterChannelContentFromKvCache } }
    set { set(\.filterChannelContentFromKvCache, to: newValue) }
  }

  /// Whether to enable Metal residency set on GPU.
  ///
  /// If true, the GPU backend will use MTLResidencySet to prevent memory swapping on macOS.
  public static var gpuEnableMetalResidencySet: Bool? {
    get { values.withLock { $0.gpuEnableMetalResidencySet } }
    set { set(\.gpuEnableMetalResidencySet, to: newValue) }
  }

  /// Whether YNNPACK should delegate supported CPU operations before XNNPACK.
  ///
  /// If nil, use the engine's default. If true, force enable YNNPACK. If false, force disable
  /// YNNPACK.
  ///
  /// Note: This flag is read only when a new [Engine] is initialized or [benchmark] is called.
  /// Changing this value will not affect any existing [Engine] or [Conversation] instances.
  ///
  /// This feature requires build-time flag "--define=litert_enable_ynnpack=true". The release
  /// version might not have it.
  public static var enableYnnpack: Bool? {
    get {
      if let ynnpack = values.withLock({ $0.enableYnnpack }) {
        return ynnpack
      }
      let env = ProcessInfo.processInfo.environment
      if env["ENABLE_YNNPACK"] == "true" || env["enable_ynnpack"] == "true" {
        return true
      }
      if ProcessInfo.processInfo.arguments.contains(where: { $0.contains("enable_ynnpack=true") }) {
        return true
      }
      return nil
    }
    set { set(\.enableYnnpack, to: newValue) }
  }

  // Prevent initializing the struct
  private init() {}
}
