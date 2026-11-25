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
// split CLiteRTLM status helpers out of LiteRTLMError so LiteRTLMTools stays pure Swift.

import Foundation
import CLiteRTLM
#if canImport(LiteRTLMTools)
  import LiteRTLMTools
#endif

extension LiteRTLMError {
  // MARK: - Native Error Management APIs

  /// Returns the last error message recorded by the native LiteRT-LM C API on the calling thread,
  /// or `nil` if no error has occurred or the error state has been cleared.
  ///
  /// - Note: The native C API uses thread-local storage. When calling `async` Swift methods,
  ///   the operation may suspend and resume on a different thread. To inspect errors across
  ///   `async` operations, prefer inspecting the thrown `LiteRTLMError`, which captures the native
  ///   error message immediately on the invoking thread.
  public static func getLastErrorMessage() -> String? {
    guard let cString = litert_lm_get_last_error_message() else {
      return nil
    }
    return String(cString: cString)
  }

  /// Clears the last error recorded by the native LiteRT-LM C API on the calling thread,
  /// resetting the error message to `nil`.
  public static func clearLastError() {
    litert_lm_clear_last_error()
  }

  /// Retrieves the last error message recorded on the calling thread and clears the thread-local
  /// error state. Returns `nil` if no error has occurred or if the recorded message is empty.
  internal static func consumeLastError() -> String? {
    defer { litert_lm_clear_last_error() }
    guard let cString = litert_lm_get_last_error_message() else {
      return nil
    }
    let message = String(cString: cString)
    return message.isEmpty ? nil : message
  }

  /// Checks the `LiteRtLmStatusCode` returned by the native C API function `functionName`.
  ///
  /// Must be called on the thread that made the native call, immediately after it, because the
  /// native error message is stored in thread-local storage.
  ///
  /// - Parameters:
  ///   - status: The status code returned by the native call.
  ///   - functionName: The name of the native function, used in the error details.
  ///   - makeError: Builds the error to throw from a description of the failure.
  /// - Throws: The error built by `makeError` if `status` is not `kLiteRtLmStatusOk`. Its details
  ///   contain `functionName`, the status code and the native last error message.
  static func check(
    _ status: LiteRtLmStatusCode, _ functionName: String, _ makeError: (String) -> LiteRTLMError
  ) throws {
    guard status == kLiteRtLmStatusOk else {
      let message = consumeLastError() ?? "no error message available"
      throw makeError("\(functionName) failed with status \(status.rawValue): \(message)")
    }
  }

  /// Calls a native constructor that returns a status code and writes the new handle to an
  /// out-parameter, and returns the handle.
  ///
  /// `body` must make the native call synchronously on the calling thread, passing its argument
  /// as the out-parameter.
  ///
  /// - Parameters:
  ///   - functionName: The name of the native function, used in the error details.
  ///   - makeError: Builds the error to throw from a description of the failure.
  ///   - body: Calls the native constructor with the given out-parameter and returns its status.
  /// - Returns: The created handle, owned by the caller.
  /// - Throws: The error built by `makeError` if the call fails or produces no handle.
  static func create(
    _ functionName: String, _ makeError: (String) -> LiteRTLMError,
    _ body: (UnsafeMutablePointer<OpaquePointer?>) -> LiteRtLmStatusCode
  ) throws -> OpaquePointer {
    var handle: OpaquePointer?
    try check(body(&handle), functionName, makeError)
    guard let handle else {
      throw makeError("\(functionName) returned a null handle")
    }
    return handle
  }

  /// Calls a native accessor that returns a status code and writes its result to an
  /// out-parameter, and returns the result.
  ///
  /// `body` must make the native call synchronously on the calling thread, passing its argument
  /// as the out-parameter.
  ///
  /// - Parameters:
  ///   - initialValue: The value the out-parameter holds before the call.
  ///   - functionName: The name of the native function, used in the error details.
  ///   - makeError: Builds the error to throw from a description of the failure.
  ///   - body: Calls the native accessor with the given out-parameter and returns its status.
  /// - Returns: The value written to the out-parameter.
  /// - Throws: The error built by `makeError` if the call fails.
  static func get<T>(
    _ initialValue: T, _ functionName: String, _ makeError: (String) -> LiteRTLMError,
    _ body: (UnsafeMutablePointer<T>) -> LiteRtLmStatusCode
  ) throws -> T {
    var value = initialValue
    try check(body(&value), functionName, makeError)
    return value
  }

}
