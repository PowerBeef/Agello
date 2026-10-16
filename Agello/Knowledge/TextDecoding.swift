import Foundation

/// Text from bytes in whatever encoding they came in (text files, web pages): a byte-order mark,
/// then the declared charset (an HTTP header or an HTML `<meta>`), strict UTF-8, Foundation's
/// detector (Windows-1252, Shift-JIS, GB18030, EUC-KR, Big5…), and Windows-1252 or Latin-1 last,
/// so it never fails. Pure (unit-tested).
enum TextDecoding {
  static func decode(_ data: Data, declared charset: String? = nil) -> String {
    if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
      return text
    }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
      let text = String(data: data, encoding: .utf16)
    {
      return text
    }
    if let charset, let encoding = encoding(ianaName: charset),
      let text = String(data: data, encoding: encoding)
    {
      return text
    }
    if let text = String(data: data, encoding: .utf8) { return text }
    var converted: NSString?
    var lossy = ObjCBool(false)
    let detected = NSString.stringEncoding(
      for: data,
      encodingOptions: [
        .suggestedEncodingsKey: suggested.map(\.rawValue),
        .allowLossyKey: false,
      ],
      convertedString: &converted, usedLossyConversion: &lossy)
    if detected != 0, let converted, !lossy.boolValue { return converted as String }
    return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
  }

  /// Encodings the detector weighs first: Western, Japanese, Chinese, Korean, Cyrillic.
  private static let suggested: [String.Encoding] = [
    .windowsCP1252, .isoLatin1, .shiftJIS, .japaneseEUC, .windowsCP1251,
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.big5.rawValue))),
  ]

  /// The encoding an IANA charset name stands for ("utf-8", "Shift_JIS", "windows-1252"…).
  static func encoding(ianaName: String) -> String.Encoding? {
    let name = ianaName.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
    // Browsers read Latin-1 labels as Windows-1252, its superset.
    if ["iso-8859-1", "latin1", "us-ascii", "ascii"].contains(name) { return .windowsCP1252 }
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
  }

  /// The charset an HTML page declares in its first 4 KB (`<meta charset>` or `http-equiv`).
  static func htmlCharset(in data: Data) -> String? {
    let head = String(decoding: data.prefix(4_096), as: UTF8.self)
    let pattern = #"(?i)<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)"#
    guard let range = head.range(of: pattern, options: .regularExpression) else { return nil }
    let match = String(head[range])
    guard let equals = match.range(of: "=", options: .backwards) else { return nil }
    let value = match[equals.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    return value.isEmpty ? nil : value
  }
}
