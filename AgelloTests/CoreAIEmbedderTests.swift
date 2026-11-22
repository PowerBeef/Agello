import Foundation
import XCTest

@testable import Agello

final class CoreAIEmbedderTests: XCTestCase {
  func testSentencePieceBPEUserDefinedAndByteFallback() throws {
    var pieces: [SentencePieceTokenizer.Piece] = [
      .init(text: "<pad>", score: 0, type: .control),
      .init(text: "<eos>", score: 0, type: .control),
      .init(text: "<bos>", score: 0, type: .control),
      .init(text: "<unk>", score: 0, type: .unknown),
      .init(text: "\u{2581}\u{2581}", score: 0, type: .userDefined),  // id 4
      .init(text: "<code>", score: 0, type: .userDefined),  // id 5
      .init(text: "\u{2581}", score: -10, type: .normal),  // id 6
      .init(text: "a", score: -11, type: .normal),  // id 7
      .init(text: "b", score: -12, type: .normal),  // id 8
      .init(text: "c", score: -13, type: .normal),  // id 9
      .init(text: "ab", score: -1, type: .normal),  // id 10 (highest merge score)
      .init(text: "bc", score: -2, type: .normal),  // id 11
      .init(text: "abc", score: -3, type: .normal),  // id 12
      .init(text: "\u{2581}ab", score: -0.5, type: .normal),  // id 13
    ]
    // Add all 256 byte fallback tokens starting at id 14.
    let byteBase = Int32(pieces.count)
    for byte in 0..<256 {
      pieces.append(.init(text: String(format: "<0x%02X>", byte), score: 0, type: .byte))
    }

    let tokenizer = SentencePieceTokenizer(pieces: pieces)

    // Higher score merge wins: " ab" -> "▁ab" (score -0.5) over "ab" (-1).
    XCTAssertEqual(tokenizer.encode(" ab"), [13])
    // "abc" merges "ab" (-1) first, then "ab"+"c" -> "abc" (-3).
    XCTAssertEqual(tokenizer.encode("abc"), [12])
    // Double space matches userDefined "▁▁" (4) before BPE span; <code> matches userDefined (5).
    XCTAssertEqual(tokenizer.encode("a  <code>abc"), [7, 4, 5, 12])
    // Unknown scalar "z" (0x7A) falls back to its UTF-8 byte token.
    XCTAssertEqual(tokenizer.encode("z"), [byteBase + 0x7A])
    // Multi-byte unknown scalar "é" (0xC3 0xA9) emits both UTF-8 bytes.
    XCTAssertEqual(tokenizer.encode("é"), [byteBase + 0xC3, byteBase + 0xA9])
    // Truncation preserves BOS at front and EOS at end.
    XCTAssertEqual(tokenizer.encodeWithSpecialTokens("a b c", maxLength: 4), [2, 7, 6, 1])
  }

  func testSentencePieceProtobufRoundTrip() throws {
    // Build a minimal valid ModelProto binary with 2 pieces + trainer_spec + normalizer_spec.
    var proto = Data()
    func appendVarint(_ value: UInt64, to data: inout Data) {
      var v = value
      while v >= 0x80 {
        data.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
      }
      data.append(UInt8(v))
    }
    func appendLengthDelimited(field: UInt64, payload: Data, to data: inout Data) {
      appendVarint((field << 3) | 2, to: &data)
      appendVarint(UInt64(payload.count), to: &data)
      data.append(payload)
    }
    func pieceProto(_ text: String, score: Float, type: UInt64) -> Data {
      var p = Data()
      appendLengthDelimited(field: 1, payload: Data(text.utf8), to: &p)
      appendVarint((2 << 3) | 5, to: &p)
      var bits = score.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { p.append(contentsOf: $0) }
      appendVarint((3 << 3) | 0, to: &p)
      appendVarint(type, to: &p)
      return p
    }
    appendLengthDelimited(field: 1, payload: pieceProto("<pad>", score: 0, type: 3), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("<eos>", score: 0, type: 3), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("<bos>", score: 0, type: 3), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("<unk>", score: 0, type: 2), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("hi", score: -1.5, type: 1), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("h", score: -5, type: 1), to: &proto)
    appendLengthDelimited(field: 1, payload: pieceProto("i", score: -6, type: 1), to: &proto)

    let tokenizer = try SentencePieceTokenizer(modelProtoData: proto)
    XCTAssertEqual(tokenizer.vocabSize, 7)
    XCTAssertEqual(tokenizer.bosID, 2)
    XCTAssertEqual(tokenizer.eosID, 1)
    XCTAssertEqual(tokenizer.encode("hi"), [4])
  }

  func testINT4EmbeddingTableDequantizesSignedNibbles() throws {
    // 2 vocab rows, dim = 4, mul = 2.0
    var data = Data()
    func appendLE<T: FixedWidthInteger>(_ v: T) {
      var le = v.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "AGET".utf8)
    appendLE(UInt32(1))  // version
    appendLE(UInt32(2))  // vocabSize
    appendLE(UInt32(4))  // dimension
    appendLE(Float(2.0).bitPattern)  // scaleMultiplier
    data.append(Data(count: 12))  // reserved -> 32-byte header
    // Row scales: row 0 = 0.5, row 1 = 0.25
    appendLE(Float(0.5).bitPattern)
    appendLE(Float(0.25).bitPattern)
    // Row 0 packed nibbles: lo=0, hi=7 -> 0x70; lo=-8 (0x8), hi=-1 (0xF) -> 0xF8
    data.append(contentsOf: [0x70, 0xF8])
    // Row 1 packed nibbles: lo=2, hi=-4 (0xC) -> 0xC2; lo=1, hi=-2 (0xE) -> 0xE1
    data.append(contentsOf: [0xC2, 0xE1])

    let table = try INT4EmbeddingTable(data: data)
    XCTAssertEqual(table.vocabSize, 2)
    XCTAssertEqual(table.dimension, 4)

    var out = [Float16](repeating: 0, count: 12)
    out.withUnsafeMutableBufferPointer { buf in
      // Row 1, Row 0, padded with Row 0 (bucket 3)
      table.fillFloat16(tokenIDs: [1, 0], bucketLength: 3, into: buf.baseAddress!)
    }
    // Row 1 * 0.25 * 2.0 = * 0.5: [2, -4, 1, -2] * 0.5 = [1.0, -2.0, 0.5, -1.0]
    XCTAssertEqual(Float(out[0]), 1.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[1]), -2.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[2]), 0.5, accuracy: 1e-3)
    XCTAssertEqual(Float(out[3]), -1.0, accuracy: 1e-3)
    // Row 0 * 0.5 * 2.0 = * 1.0: [0, 7, -8, -1]
    XCTAssertEqual(Float(out[4]), 0.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[5]), 7.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[6]), -8.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[7]), -1.0, accuracy: 1e-3)
    // Padded slot 2 repeats row 0
    XCTAssertEqual(Float(out[9]), 7.0, accuracy: 1e-3)
    XCTAssertEqual(Float(out[10]), -8.0, accuracy: 1e-3)
  }

  func testCoreAIEmbedderBucketSelection() {
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 1), 128)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 128), 128)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 129), 256)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 256), 256)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 400), 512)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 513), 1024)
    XCTAssertEqual(CoreAIEmbedder.bucket(for: 2000), 1024)
  }
}
