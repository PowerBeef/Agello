import Foundation

/// Deterministic CSV/TSV/JSON table parser and query engine for on-device analytics.
/// Pure and unit-tested so E4B can compute exact counts, sums, averages, min/max,
/// grouped aggregations, filtering, and sorting without mental arithmetic errors.
enum StructuredDataQuery {
  enum QueryError: Error, LocalizedError, Equatable {
    case emptyInput
    case unreadableFormat
    case unknownOperation(String)
    case unknownColumn(String, available: [String])
    case missingColumn(String)
    case invalidFilter(String)
    case noNumericValues(String)

    var errorDescription: String? {
      switch self {
      case .emptyInput:
        return "No table or JSON data was provided."
      case .unreadableFormat:
        return "Could not parse the input as CSV, TSV, or JSON."
      case .unknownOperation(let op):
        return "Unknown operation '\(op)'. Use schema, filter, count, sum, avg, min, max, or aggregate."
      case .unknownColumn(let name, let available):
        return "Column '\(name)' not found. Available columns: \(available.joined(separator: ", "))."
      case .missingColumn(let op):
        return "Operation '\(op)' requires a column name."
      case .invalidFilter(let clause):
        return "Could not parse filter '\(clause)'. Use forms like \"region = West\" or \"amount >= 100\"."
      case .noNumericValues(let column):
        return "Column '\(column)' contains no numeric values in the matching rows."
      }
    }
  }

  struct Table: Equatable, Sendable {
    var columns: [String]
    var rows: [[String: String]]
    var format: String
  }

  struct Request: Equatable, Sendable {
    var operation: String
    var column: String?
    var whereClause: String?
    var groupBy: String?
    var sortBy: String?
    var descending: Bool = false
    var limit: Int = 20
  }

  struct Output: Equatable, Sendable {
    var format: String
    var totalRows: Int
    var matchedRows: Int
    var columns: [String]
    var summary: String
  }

  /// Parse raw text as JSON (array of objects, wrapped array, or single object) or CSV/TSV/semicolon table.
  static func parse(_ raw: String) throws -> Table {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw QueryError.emptyInput }
    if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
      if let table = parseJSON(trimmed) { return table }
    }
    if let table = parseDelimited(trimmed) { return table }
    throw QueryError.unreadableFormat
  }

  /// Execute a structured query over `raw` CSV/TSV/JSON data and return a compact deterministic summary.
  static func execute(raw: String, request: Request) throws -> Output {
    let table = try parse(raw)
    let op = request.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let cappedLimit = max(1, min(50, request.limit))

    let predicates = try parsePredicates(request.whereClause, columns: table.columns)
    let filtered = table.rows.filter { row in predicates.allSatisfy { $0.matches(row) } }

    switch op {
    case "schema", "describe", "info":
      return describe(table: table, matched: filtered)
    case "filter", "select", "rows", "list", "top":
      return try selectRows(
        table: table, matched: filtered, sortBy: request.sortBy, descending: request.descending,
        limit: cappedLimit)
    case "count", "sum", "avg", "average", "mean", "min", "max", "aggregate", "stats":
      return try aggregate(
        table: table, matched: filtered, operation: op, column: request.column,
        groupBy: request.groupBy, descending: request.descending, limit: cappedLimit)
    default:
      throw QueryError.unknownOperation(request.operation)
    }
  }

  // MARK: - Operations

  private static func describe(table: Table, matched: [[String: String]]) -> Output {
    let types = table.columns.map { column -> String in
      let values = matched.compactMap { $0[column] }.filter { !$0.isEmpty }
      let numeric = values.filter { parseNumber($0) != nil }.count
      let kind = !values.isEmpty && numeric == values.count ? "number" : "string"
      return "\(column) (\(kind))"
    }
    var lines = [
      "Format: \(table.format) · \(table.rows.count) rows · \(table.columns.count) columns",
      "Columns: \(types.joined(separator: ", "))",
    ]
    let samples = matched.prefix(3)
    if !samples.isEmpty {
      lines.append("Sample rows:")
      for (index, row) in samples.enumerated() {
        let fields = table.columns.map { "\($0)=\(row[$0] ?? "")" }.joined(separator: " | ")
        lines.append("\(index + 1). \(fields)")
      }
    }
    return Output(
      format: table.format, totalRows: table.rows.count, matchedRows: matched.count,
      columns: table.columns, summary: lines.joined(separator: "\n"))
  }

  private static func selectRows(
    table: Table, matched: [[String: String]], sortBy: String?, descending: Bool, limit: Int
  ) throws -> Output {
    var rows = matched
    if let sortBy, !sortBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let col = try resolveColumn(sortBy, in: table.columns)
      rows.sort { lhs, rhs in
        let cmp = compareValues(lhs[col] ?? "", rhs[col] ?? "")
        return descending ? cmp == .orderedDescending : cmp == .orderedAscending
      }
    }
    let shown = rows.prefix(limit)
    var lines = ["Matched \(matched.count) of \(table.rows.count) rows (showing \(shown.count)):"]
    lines.append(table.columns.joined(separator: " | "))
    for row in shown {
      lines.append(table.columns.map { row[$0] ?? "" }.joined(separator: " | "))
    }
    return Output(
      format: table.format, totalRows: table.rows.count, matchedRows: matched.count,
      columns: table.columns, summary: lines.joined(separator: "\n"))
  }

  private static func aggregate(
    table: Table, matched: [[String: String]], operation: String, column rawColumn: String?,
    groupBy rawGroupBy: String?, descending: Bool, limit: Int
  ) throws -> Output {
    let metric = normalizeMetric(operation)
    let resolvedColumn: String?
    if let rawColumn, !rawColumn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      resolvedColumn = try resolveColumn(rawColumn, in: table.columns)
    } else if metric == "count" {
      resolvedColumn = nil
    } else {
      throw QueryError.missingColumn(operation)
    }

    if let rawGroupBy, !rawGroupBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let groupCol = try resolveColumn(rawGroupBy, in: table.columns)
      var buckets: [String: [[String: String]]] = [:]
      for row in matched {
        let key = row[groupCol]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (key?.isEmpty == false) ? key! : "(empty)"
        buckets[label, default: []].append(row)
      }
      var entries: [(key: String, score: Double, line: String)] = []
      for (key, groupRows) in buckets {
        let stats = try computeStats(rows: groupRows, column: resolvedColumn, metric: metric)
        entries.append((key: key, score: stats.primaryValue, line: "\(key): \(stats.line)"))
      }
      entries.sort { lhs, rhs in
        if lhs.score != rhs.score { return descending ? lhs.score > rhs.score : lhs.score < rhs.score }
        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
      }
      let shown = entries.prefix(limit)
      var lines = [
        "Grouped by \(groupCol) (\(buckets.count) groups across \(matched.count) matched rows):"
      ]
      lines.append(contentsOf: shown.map(\.line))
      return Output(
        format: table.format, totalRows: table.rows.count, matchedRows: matched.count,
        columns: table.columns, summary: lines.joined(separator: "\n"))
    }

    let stats = try computeStats(rows: matched, column: resolvedColumn, metric: metric)
    let header = resolvedColumn.map { "\(metric)(\($0)) over \(matched.count) of \(table.rows.count) rows" }
      ?? "count over \(matched.count) of \(table.rows.count) rows"
    return Output(
      format: table.format, totalRows: table.rows.count, matchedRows: matched.count,
      columns: table.columns, summary: "\(header)\n\(stats.line)")
  }

  private static func normalizeMetric(_ op: String) -> String {
    switch op {
    case "average", "mean": return "avg"
    case "stats": return "aggregate"
    default: return op
    }
  }

  private static func computeStats(
    rows: [[String: String]], column: String?, metric: String
  ) throws -> (primaryValue: Double, line: String) {
    guard let column else {
      return (Double(rows.count), "count=\(rows.count)")
    }
    let numbers = rows.compactMap { row -> Double? in
      guard let raw = row[column] else { return nil }
      return parseNumber(raw)
    }
    if metric == "count" {
      let nonEmpty = rows.filter { !($0[column]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }.count
      return (Double(nonEmpty), "count=\(nonEmpty) (rows=\(rows.count))")
    }
    guard !numbers.isEmpty else { throw QueryError.noNumericValues(column) }
    let sum = numbers.reduce(0, +)
    let avg = sum / Double(numbers.count)
    let minVal = numbers.min() ?? 0
    let maxVal = numbers.max() ?? 0
    switch metric {
    case "sum": return (sum, "sum=\(fmt(sum)) (n=\(numbers.count))")
    case "avg": return (avg, "avg=\(fmt(avg)) (n=\(numbers.count))")
    case "min": return (minVal, "min=\(fmt(minVal)) (n=\(numbers.count))")
    case "max": return (maxVal, "max=\(fmt(maxVal)) (n=\(numbers.count))")
    default:
      return (
        sum,
        "count=\(numbers.count), sum=\(fmt(sum)), avg=\(fmt(avg)), min=\(fmt(minVal)), max=\(fmt(maxVal))"
      )
    }
  }

  // MARK: - Filtering

  private struct Predicate {
    enum Op { case eq, neq, gt, gte, lt, lte, contains, startsWith, endsWith }
    var column: String
    var op: Op
    var value: String

    func matches(_ row: [String: String]) -> Bool {
      let cell = (row[column] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      switch op {
      case .eq:
        if let a = parseNumber(cell), let b = parseNumber(value) { return a == b }
        return cell.caseInsensitiveCompare(value) == .orderedSame
      case .neq:
        if let a = parseNumber(cell), let b = parseNumber(value) { return a != b }
        return cell.caseInsensitiveCompare(value) != .orderedSame
      case .gt: return compareValues(cell, value) == .orderedDescending
      case .gte:
        let c = compareValues(cell, value)
        return c == .orderedDescending || c == .orderedSame
      case .lt: return compareValues(cell, value) == .orderedAscending
      case .lte:
        let c = compareValues(cell, value)
        return c == .orderedAscending || c == .orderedSame
      case .contains: return cell.localizedCaseInsensitiveContains(value)
      case .startsWith: return cell.lowercased().hasPrefix(value.lowercased())
      case .endsWith: return cell.lowercased().hasSuffix(value.lowercased())
      }
    }
  }

  private static func parsePredicates(_ clause: String?, columns: [String]) throws -> [Predicate] {
    guard let clause else { return [] }
    let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let parts = splitAndClauses(trimmed)
    return try parts.map { part in
      try parseSinglePredicate(part, columns: columns)
    }
  }

  private static func splitAndClauses(_ text: String) -> [String] {
    let regex = try? NSRegularExpression(pattern: #"\s+and\s+"#, options: .caseInsensitive)
    let ns = text as NSString
    let matches = regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
    var parts: [String] = []
    var start = 0
    for match in matches {
      parts.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
      start = match.range.location + match.range.length
    }
    parts.append(ns.substring(from: start))
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  private static func parseSinglePredicate(_ clause: String, columns: [String]) throws -> Predicate {
    let operators: [(String, Predicate.Op)] = [
      (">=", .gte), ("<=", .lte), ("!=", .neq), ("==", .eq),
      (" contains ", .contains), (" startswith ", .startsWith), (" endswith ", .endsWith),
      ("=", .eq), (">", .gt), ("<", .lt),
    ]
    for (token, op) in operators {
      if let range = clause.range(of: token, options: .caseInsensitive) {
        let lhs = clause[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var rhs = clause[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if (rhs.hasPrefix("\"") && rhs.hasSuffix("\"")) || (rhs.hasPrefix("'") && rhs.hasSuffix("'")),
          rhs.count >= 2
        {
          rhs = String(rhs.dropFirst().dropLast())
        }
        guard !lhs.isEmpty else { throw QueryError.invalidFilter(clause) }
        let column = try resolveColumn(lhs, in: columns)
        return Predicate(column: column, op: op, value: rhs)
      }
    }
    throw QueryError.invalidFilter(clause)
  }

  private static func resolveColumn(_ name: String, in columns: [String]) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let exact = columns.first(where: { $0 == trimmed }) { return exact }
    if let ci = columns.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return ci }
    let normalized = trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
    if let loose = columns.first(where: {
      $0.lowercased().replacingOccurrences(of: " ", with: "_") == normalized
    }) {
      return loose
    }
    throw QueryError.unknownColumn(trimmed, available: columns)
  }

  private static func compareValues(_ a: String, _ b: String) -> ComparisonResult {
    if let numA = parseNumber(a), let numB = parseNumber(b) {
      if numA < numB { return .orderedAscending }
      if numA > numB { return .orderedDescending }
      return .orderedSame
    }
    return a.localizedCaseInsensitiveCompare(b)
  }

  /// Parses plain, currency-prefixed, comma-grouped (US & European), or percent numbers.
  static func parseNumber(_ raw: String) -> Double? {
    LanguageSupport.parseLocalizedNumber(raw)
  }

  private static func fmt(_ value: Double) -> String {
    let rounded = Double(String(format: "%.10g", value)) ?? value
    let clean = rounded == 0 ? 0 : rounded
    if clean.rounded() == clean, abs(clean) < 1e12 {
      return String(format: "%.0f", clean)
    }
    return String(format: "%.10g", clean)
  }

  // MARK: - Parsers (JSON + RFC-4180 CSV/TSV)

  private static func parseJSON(_ raw: String) -> Table? {
    guard let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    let objects: [[String: Any]]
    if let array = json as? [[String: Any]] {
      objects = array
    } else if let dict = json as? [String: Any] {
      if let nested = dict.values.compactMap({ $0 as? [[String: Any]] }).first {
        objects = nested
      } else {
        objects = [dict]
      }
    } else {
      return nil
    }
    guard !objects.isEmpty else { return nil }
    var columns: [String] = []
    var seen = Set<String>()
    var rows: [[String: String]] = []
    for obj in objects {
      var flat: [String: String] = [:]
      flattenJSON(obj, prefix: "", into: &flat, columns: &columns, seen: &seen)
      rows.append(flat)
    }
    guard !columns.isEmpty else { return nil }
    return Table(columns: columns, rows: rows, format: "JSON")
  }

  private static func flattenJSON(
    _ dict: [String: Any], prefix: String, into flat: inout [String: String],
    columns: inout [String], seen: inout Set<String>
  ) {
    for key in dict.keys.sorted() {
      let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
      let value = dict[key]
      if let sub = value as? [String: Any] {
        flattenJSON(sub, prefix: fullKey, into: &flat, columns: &columns, seen: &seen)
      } else {
        if seen.insert(fullKey).inserted { columns.append(fullKey) }
        flat[fullKey] = stringifyJSON(value)
      }
    }
  }

  private static func stringifyJSON(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
      return number.stringValue
    }
    if let string = value as? String { return string }
    if let array = value as? [Any] {
      return array.map { stringifyJSON($0) }.joined(separator: ", ")
    }
    return String(describing: value)
  }

  private static func parseDelimited(_ raw: String) -> Table? {
    let delimiter = detectDelimiter(raw)
    let records = parseRFC4180(raw, delimiter: delimiter)
      .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    guard records.count >= 2 else { return nil }
    let header = records[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard header.count >= 2 || (header.count == 1 && !header[0].isEmpty) else { return nil }
    // Ensure unique non-empty column names.
    var columns: [String] = []
    var seen = Set<String>()
    for (index, rawName) in header.enumerated() {
      var name = rawName.isEmpty ? "col_\(index + 1)" : rawName
      var suffix = 2
      while !seen.insert(name).inserted {
        name = "\(rawName)_\(suffix)"
        suffix += 1
      }
      columns.append(name)
    }
    var rows: [[String: String]] = []
    for record in records.dropFirst() {
      var dict: [String: String] = [:]
      for (index, col) in columns.enumerated() {
        dict[col] = index < record.count ? record[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
      }
      rows.append(dict)
    }
    let format = delimiter == "\t" ? "TSV" : "CSV"
    return Table(columns: columns, rows: rows, format: format)
  }

  private static func detectDelimiter(_ raw: String) -> Character {
    let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
    let candidates: [Character] = [",", "\t", ";"]
    var best: Character = ","
    var bestCount = 0
    for sep in candidates {
      let count = parseRFC4180(firstLine, delimiter: sep).first?.count ?? 0
      if count > bestCount {
        bestCount = count
        best = sep
      }
    }
    return best
  }

  private static func parseRFC4180(_ text: String, delimiter: Character) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if inQuotes {
        if c == "\"" {
          if i + 1 < chars.count, chars[i + 1] == "\"" {
            field.append("\"")
            i += 2
            continue
          }
          inQuotes = false
        } else {
          field.append(c)
        }
      } else {
        if c == "\"" && field.isEmpty {
          inQuotes = true
        } else if c == delimiter {
          row.append(field)
          field = ""
        } else if c == "\r" || c == "\n" {
          if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
          row.append(field)
          rows.append(row)
          row = []
          field = ""
        } else {
          field.append(c)
        }
      }
      i += 1
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }
}
