import XCTest

@testable import Agello

final class InferencePlannerTests: XCTestCase {
  private let roomy: UInt64 = 8_000_000_000
  private let tight: UInt64 = 6_000_000_000

  func testDefaultsE2BRoomy() {
    let resolved = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    XCTAssertTrue(resolved.useGPU)
    XCTAssertEqual(resolved.maxNumTokens, 8192)
    XCTAssertNil(resolved.thinkingBudget)
    XCTAssertEqual(resolved.visualTokenBudget, 280)
    XCTAssertTrue(resolved.enableSpeculativeDecoding)
    XCTAssertEqual(resolved.topK, 40)
    XCTAssertEqual(resolved.topP, 0.95)
    XCTAssertEqual(resolved.temperature, 0.7)
  }

  func testTightDeviceGetsSmallerCache() {
    let tightPlan = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: tight)
    XCTAssertEqual(tightPlan.maxNumTokens, 4096)

    let e4b = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    XCTAssertEqual(e4b.maxNumTokens, 8192)
  }

  func testOverrideIsClamped() {
    var options = InferenceOptions()
    options.maxNumTokensOverride = 10
    XCTAssertEqual(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).maxNumTokens,
      256)
    options.maxNumTokensOverride = 200_000
    XCTAssertEqual(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).maxNumTokens,
      InferencePlanner.maxTokens)
  }

  /// A 32K request allocates 32,000 positions; budgets must use what exists.
  func testThirtyTwoKMeansTheAllocatedThirtyTwoThousand() {
    var options = InferenceOptions()
    options.maxNumTokensOverride = 32_768
    XCTAssertEqual(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).maxNumTokens,
      32_000)
    options.maxNumTokensOverride = 16_384
    XCTAssertEqual(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).maxNumTokens,
      16_384)
  }

  func testThinkingBudget() {
    var options = InferenceOptions()
    options.enableThinking = true
    options.thinkingBudget = 512
    XCTAssertEqual(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).thinkingBudget,
      512)

    options.enableThinking = false
    XCTAssertNil(
      InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy).thinkingBudget)
  }

  func testVisionOffDropsVisualBudget() {
    var options = InferenceOptions()
    options.enableVision = false
    let resolved = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    XCTAssertFalse(resolved.enableVision)
    XCTAssertNil(resolved.visualTokenBudget)
  }

  func testAttemptLadderPrefersGPUMultimodal() {
    let plan = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    let attempts = InferencePlanner.attempts(for: plan)
    XCTAssertEqual(attempts.count, 4)
    XCTAssertEqual(attempts.map(\.useGPU), [true, true, false, false])
    XCTAssertEqual(attempts.map(\.enableVision), [true, false, true, false])
    XCTAssertEqual(attempts.map(\.enableAudio), [true, false, true, false])
    // Text-only attempts drop the visual budget too.
    XCTAssertNil(attempts[1].visualTokenBudget)
    XCTAssertEqual(attempts[0].visualTokenBudget, 280)
  }

  func testAttemptLadderCpuPreferred() {
    var options = InferenceOptions()
    options.backendPreference = .cpu
    let plan = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    let attempts = InferencePlanner.attempts(for: plan)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertTrue(attempts.allSatisfy { !$0.useGPU })
  }

  func testAttemptLadderDedupesWhenMultimodalOff() {
    var options = InferenceOptions()
    options.enableVision = false
    options.enableAudio = false
    let plan = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    let attempts = InferencePlanner.attempts(for: plan)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts.map(\.useGPU), [true, false])
  }

  func testApplyCapabilitiesDisablesUnsupported() {
    var options = InferenceOptions()
    options.enableThinking = true
    let plan = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    let caps = ModelCapabilities(
      speculativeDecoding: false, thinking: false, functionCalling: false,
      vision: false, audio: false, maxVisionTokenBudget: -1,
      maxContextTokens: 0, dynamicContext: true)
    let out = InferencePlanner.applyCapabilities(caps, to: plan)
    XCTAssertFalse(out.enableSpeculativeDecoding)
    // Device finding: the thinking flag is unreliable (E2B reports false yet
    // reasons), so thinking is never stripped.
    XCTAssertEqual(out.thinkingBudget, plan.thinkingBudget)
    XCTAssertFalse(out.enableVision)
    XCTAssertFalse(out.enableAudio)
    XCTAssertNil(out.visualTokenBudget)
    XCTAssertEqual(out.maxNumTokens, plan.maxNumTokens)
  }

  func testApplyCapabilitiesClampsToModelLimits() {
    var options = InferenceOptions()
    options.visualDetail = .detailed // 560
    options.maxNumTokensOverride = 8192
    let plan = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    let caps = ModelCapabilities(
      speculativeDecoding: true, thinking: true, functionCalling: true,
      vision: true, audio: true, maxVisionTokenBudget: 280,
      maxContextTokens: 2048, dynamicContext: false)
    let out = InferencePlanner.applyCapabilities(caps, to: plan)
    XCTAssertEqual(out.visualTokenBudget, 280)
    XCTAssertEqual(out.maxNumTokens, 2048)
    XCTAssertTrue(out.enableSpeculativeDecoding)
  }

  func testApplyCapabilitiesFullKeepsPlan() {
    let plan = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    XCTAssertEqual(InferencePlanner.applyCapabilities(.full, to: plan), plan)
  }

  // MARK: - Engine reload vs. conversation update (audit #4)

  func testEngineLevelChangesRequireReload() {
    let base = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    for mutate in [
      { (o: inout InferenceOptions) in o.enableVision = false },
      { (o: inout InferenceOptions) in o.enableAudio = false },
      { (o: inout InferenceOptions) in o.backendPreference = .cpu },
      { (o: inout InferenceOptions) in o.maxNumTokensOverride = 1024 },
      { (o: inout InferenceOptions) in o.enableSpeculativeDecoding = false },
    ] {
      var options = InferenceOptions()
      mutate(&options)
      let requested = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
      XCTAssertTrue(InferencePlanner.requiresEngineReload(built: base, requested: requested))
    }
  }

  func testConversationLevelChangesDoNotReload() {
    let base = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    var options = InferenceOptions()
    options.samplerPreset = .creative
    options.enableThinking = true
    options.visualDetail = .detailed
    options.systemPrompt = "Be terse."
    let requested = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    XCTAssertFalse(InferencePlanner.requiresEngineReload(built: base, requested: requested))
  }

  func testConversationUpdateKeepsEngineFallbacks() {
    var engine = InferencePlanner.resolve(
      options: InferenceOptions(), model: .e4b, memoryBytes: roomy)
    engine.useGPU = false  // GPU failed at load
    engine.enableVision = false  // no vision executor
    engine.visualTokenBudget = nil
    var options = InferenceOptions()
    options.samplerPreset = .precise
    options.visualDetail = .detailed
    let plan = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    let updated = InferencePlanner.conversationUpdate(engine: engine, plan: plan)
    XCTAssertFalse(updated.useGPU)
    XCTAssertFalse(updated.enableVision, "Must not claim vision the engine lacks")
    XCTAssertNil(updated.visualTokenBudget)
    XCTAssertEqual(updated.temperature, SamplerPreset.precise.temperature)
  }

  func testSamplerPresets() {
    var options = InferenceOptions()
    options.samplerPreset = .precise
    var resolved = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    XCTAssertEqual(resolved.topK, 20)
    XCTAssertEqual(resolved.topP, 0.9)
    XCTAssertEqual(resolved.temperature, 0.2)

    options.samplerPreset = .creative
    resolved = InferencePlanner.resolve(options: options, model: .e4b, memoryBytes: roomy)
    XCTAssertEqual(resolved.topK, 60)
    XCTAssertEqual(resolved.topP, 0.98)
    XCTAssertEqual(resolved.temperature, 1.0)
  }
}
