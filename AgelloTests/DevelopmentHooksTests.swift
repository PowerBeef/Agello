import XCTest

@testable import Agello

/// The Mac command line (docs/CLI.md) redirects three folders through the environment. In the
/// app none of the variables is set, and each hook must then leave the app's own folder alone.
final class DevelopmentHooksTests: XCTestCase {
  func testTheAppUsesItsOwnFolders() throws {
    let environment = ProcessInfo.processInfo.environment
    XCTAssertNil(environment["AGELLO_MODELS_DIR"])
    XCTAssertNil(environment["AGELLO_ENGINE_CACHE_DIR"])
    XCTAssertNil(environment["AGELLO_TRACE_DIR"])
    XCTAssertNil(ModelStore.externalModelsDirectory)
    XCTAssertNil(ReplyTrace.externalDirectory)
    let models = try ModelStore.modelsDirectory()
    XCTAssertEqual(models.lastPathComponent, "Models")
    XCTAssertTrue(models.path.contains("Application Support"))
    XCTAssertEqual(try ReplyTrace.directory().lastPathComponent, "traces")
    XCTAssertTrue(try EngineCache.embeddingDirectory().contains("com.patricedery.agello.litertlm"))
  }
}
