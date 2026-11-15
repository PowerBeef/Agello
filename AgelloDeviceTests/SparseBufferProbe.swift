import Metal
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 26: can the KV cache follow the fill on this GPU? (PERFORMANCE.md, "The engine review,
  /// adopted": memory follows each Metal buffer's size, not the fill.) A 256 MB placement sparse
  /// buffer (Metal 4, private, 64 KB tiles) with 16 MB mapped from a placement heap by an MTL4
  /// queue, written in full and read back by kernels on a classic queue (as ML Drift runs): its
  /// tier, the footprint at each step, where data landed (writes past the mapping should be
  /// dropped, reads there zero), then 16 MB more mapped. No model needed.
  func test26_SparseBufferSupport() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let queue4 = device.makeMTL4CommandQueue(), let event = device.makeSharedEvent()
    else { throw XCTSkip("No Metal device or MTL4 queue") }
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      kernel void fill(device uint* data [[buffer(0)]], constant uint& value [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) { data[id] = value; }
      kernel void sample(device const uint* data [[buffer(0)]], device uint* out [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) { out[id] = data[id * (1u << 18)]; }
      """
    let library = try device.makeLibrary(source: source, options: nil)
    let fill = try device.makeComputePipelineState(function: library.makeFunction(name: "fill")!)
    let sample = try device.makeComputePipelineState(function: library.makeFunction(name: "sample")!)
    let size = 256 << 20
    let tileBytes = 64 << 10
    var steps: [[String: Any]] = []
    func note(_ step: String, _ extra: [String: Any] = [:]) {
      steps.append(["step": step, "footprintMB": Double(MemoryProbe.footprintBytes()) / 1_048_576].merging(extra) { a, _ in a })
    }
    note("start")
    guard let sparse = device.makeBuffer(length: size, options: .storageModePrivate, placementSparsePageSize: .size64)
    else {
      harness.record("probe26_sparseBuffer", ["supported": false, "steps": steps], in: self)
      XCTFail("No placement sparse buffer on this GPU")
      return
    }
    note("sparse buffer created", ["tier": sparse.sparseBufferTier.rawValue])
    func heap() -> MTLHeap {
      let descriptor = MTLHeapDescriptor()
      descriptor.type = .placement
      descriptor.storageMode = .private
      descriptor.size = 16 << 20
      descriptor.maxCompatiblePlacementSparsePageSize = .size64
      return device.makeHeap(descriptor: descriptor)!
    }
    var eventValue: UInt64 = 0
    func map(_ heap: MTLHeap, atMB: Int) {
      let operation = MTL4UpdateSparseBufferMappingOperation(
        mode: .map, bufferRange: NSRange(location: (atMB << 20) / tileBytes, length: (16 << 20) / tileBytes),
        heapOffset: 0)
      queue4.updateMappings(buffer: sparse, heap: heap, operations: [operation])
      eventValue += 1
      queue4.signalEvent(event, value: eventValue)
      _ = event.wait(untilSignaledValue: eventValue, timeoutMS: 5000)
    }
    func run(_ body: (MTLComputeCommandEncoder) -> Void) -> String? {
      let commandBuffer = queue.makeCommandBuffer()!
      let encoder = commandBuffer.makeComputeCommandEncoder()!
      body(encoder)
      encoder.endEncoding()
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      return commandBuffer.error.map { "\($0)" }
    }
    let out = device.makeBuffer(length: 256 * 4, options: .storageModeShared)!
    func writeAll(_ value: UInt32) -> String? {
      var v = value
      return run { encoder in
        encoder.setComputePipelineState(fill)
        encoder.setBuffer(sparse, offset: 0, index: 0)
        encoder.setBytes(&v, length: 4, index: 1)
        encoder.dispatchThreads(
          MTLSize(width: size / 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
      }
    }
    func megabytesWithData() -> [Int] {
      _ = run { encoder in
        encoder.setComputePipelineState(sample)
        encoder.setBuffer(sparse, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.dispatchThreads(
          MTLSize(width: 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      }
      let words = out.contents().bindMemory(to: UInt32.self, capacity: 256)
      return (0..<256).filter { words[$0] != 0 }
    }
    let first = heap()
    note("16 MB heap")
    map(first, atMB: 0)
    let error1 = writeAll(7)
    let data1 = megabytesWithData()
    note("all 256 MB written, 16 MB mapped", ["error": error1 ?? "", "mbWithData": data1.count, "lastMB": data1.last ?? -1])
    let second = heap()
    map(second, atMB: 16)
    let error2 = writeAll(9)
    let data2 = megabytesWithData()
    note("written again, 32 MB mapped", ["error": error2 ?? "", "mbWithData": data2.count, "lastMB": data2.last ?? -1])
    harness.record(
      "probe26_sparseBuffer", ["supported": true, "tier": sparse.sparseBufferTier.rawValue, "steps": steps], in: self)
    print("probe26: \(steps)")
    XCTAssertEqual(sparse.sparseBufferTier, .tier1)
    XCTAssertEqual(data1, Array(0..<16), "writes past the mapping should be dropped and reads there zero")
    XCTAssertEqual(data2, Array(0..<32))
    let growth = (steps[4]["footprintMB"] as? Double ?? 0) - (steps[2]["footprintMB"] as? Double ?? 0)
    XCTAssertLessThan(growth, 64, "the footprint should follow the mapping (32 MB), not the buffer (256 MB)")
    withExtendedLifetime((first, second)) {}
  }
}
