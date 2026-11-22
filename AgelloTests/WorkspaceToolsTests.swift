import SwiftData
import XCTest

@testable import Agello

/// Unit tests for P5.2 workspace research tools, structured CSV/JSON analytics, unit conversions,
/// and large-context multi-step tool budgets.
final class WorkspaceToolsTests: XCTestCase {
  override func tearDown() {
    ToolBudget.reset()
    WorkspaceTools.searchFilesHandler = nil
    WorkspaceTools.readDocumentPagesHandler = nil
    WorkspaceTools.searchPastChatsHandler = nil
    WorkspaceTools.lookupDocumentTextHandler = nil
    super.tearDown()
  }

  // MARK: - UnitConverter

  func testUnitConverterStandardCategories() throws {
    let kmToMi = try UnitConverter.convert(value: 10, from: "km", to: "mi")
    XCTAssertEqual(kmToMi.outputValue, 6.213711922, accuracy: 1e-4)
    XCTAssertEqual(kmToMi.category, "length")

    let fToC = try UnitConverter.convert(value: 212, from: "°F", to: "C")
    XCTAssertEqual(fToC.outputValue, 100, accuracy: 1e-6)
    XCTAssertEqual(fToC.formatted, "100 °C")

    let cToK = try UnitConverter.convert(value: -273.15, from: "celsius", to: "kelvin")
    XCTAssertEqual(cToK.outputValue, 0, accuracy: 1e-6)

    let lbToKg = try UnitConverter.convert(value: 150, from: "lbs", to: "kg")
    XCTAssertEqual(lbToKg.outputValue, 68.0388555, accuracy: 1e-4)

    let gbToGib = try UnitConverter.convert(value: 1, from: "GB", to: "GiB")
    XCTAssertEqual(gbToGib.outputValue, 0.9313225746, accuracy: 1e-4)

    let mphToKmh = try UnitConverter.convert(value: 60, from: "mph", to: "km/h")
    XCTAssertEqual(mphToKmh.outputValue, 96.56064, accuracy: 1e-3)
  }

  func testUnitConverterErrors() {
    XCTAssertThrowsError(try UnitConverter.convert(value: 5, from: "km", to: "kg")) { error in
      XCTAssertEqual(error as? UnitConversionError, .incompatible(from: "km", to: "kg"))
    }
    XCTAssertThrowsError(try UnitConverter.convert(value: 5, from: "furlongs", to: "m")) { error in
      XCTAssertEqual(error as? UnitConversionError, .unknownUnit("furlongs"))
    }
    XCTAssertThrowsError(try UnitConverter.convert(value: .infinity, from: "m", to: "ft")) { error in
      XCTAssertEqual(error as? UnitConversionError, .notFinite)
    }
  }

  // MARK: - StructuredDataQuery

  private let sampleCSV = """
    region,product,revenue,units,notes
    North,"Widget, Pro","$1,250.50",10,"Best ""selling"" item"
    North,Gadget,$450.00,5,Standard
    West,Widget Pro,"$2,100.00",20,Bulk order
    West,Gadget,$900.25,9,Repeat
    East,Widget Pro,$750.00,6,Trial
    """

  func testCSVSchemaAndQuotedFields() throws {
    let out = try StructuredDataQuery.execute(
      raw: sampleCSV, request: .init(operation: "schema"))
    XCTAssertEqual(out.format, "CSV")
    XCTAssertEqual(out.totalRows, 5)
    XCTAssertEqual(out.columns, ["region", "product", "revenue", "units", "notes"])
    XCTAssertTrue(out.summary.contains("revenue (number)"))
    XCTAssertTrue(out.summary.contains("Widget, Pro"))
    XCTAssertTrue(out.summary.contains(#"Best "selling" item"#))
  }

  func testCSVFilterSortAndGroupedAggregation() throws {
    let sumNorth = try StructuredDataQuery.execute(
      raw: sampleCSV,
      request: .init(operation: "sum", column: "revenue", whereClause: "region = North"))
    XCTAssertEqual(sumNorth.matchedRows, 2)
    XCTAssertTrue(sumNorth.summary.contains("sum=1700.5"), sumNorth.summary)

    let grouped = try StructuredDataQuery.execute(
      raw: sampleCSV,
      request: .init(
        operation: "sum", column: "revenue", groupBy: "region", descending: true))
    XCTAssertTrue(grouped.summary.contains("West: sum=3000.25"), grouped.summary)
    XCTAssertTrue(grouped.summary.contains("North: sum=1700.5"), grouped.summary)
    XCTAssertTrue(grouped.summary.contains("East: sum=750"), grouped.summary)

    let filtered = try StructuredDataQuery.execute(
      raw: sampleCSV,
      request: .init(
        operation: "filter", whereClause: "units >= 9 AND region != East",
        sortBy: "revenue", descending: true))
    XCTAssertEqual(filtered.matchedRows, 3)
    XCTAssertTrue(filtered.summary.contains("2,100.00"), filtered.summary)
  }

  func testNestedJSONQueryAndAggregation() throws {
    let json = """
      {
        "records": [
          {"id": 1, "meta": {"team": "Core"}, "score": 92.5},
          {"id": 2, "meta": {"team": "Core"}, "score": 87.5},
          {"id": 3, "meta": {"team": "App"}, "score": 95.0}
        ]
      }
      """
    let out = try StructuredDataQuery.execute(
      raw: json,
      request: .init(operation: "avg", column: "score", whereClause: "meta.team = Core"))
    XCTAssertEqual(out.format, "JSON")
    XCTAssertEqual(out.matchedRows, 2)
    XCTAssertTrue(out.summary.contains("avg=90"), out.summary)
  }

  func testStructuredQueryErrorsAreActionable() {
    XCTAssertThrowsError(
      try StructuredDataQuery.execute(raw: sampleCSV, request: .init(operation: "sum", column: "bogus"))
    ) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("revenue"), message)
    }
    XCTAssertThrowsError(
      try StructuredDataQuery.execute(raw: sampleCSV, request: .init(operation: "sum"))
    ) { error in
      XCTAssertEqual(error as? StructuredDataQuery.QueryError, .missingColumn("sum"))
    }
  }

  // MARK: - WorkspaceTools document slicing & matching

  func testSlicePagedAndUnpagedDocuments() {
    let paged = "[Page 1]\nIntro text\n\n[Page 2]\nBudget is 4.2M\n\n[Page 3]\nConclusion"
    let p2 = WorkspaceTools.sliceDocument(
      name: "report.pdf", text: paged, pageCount: 3, startPage: 2, endPage: 2)
    XCTAssertNil(p2.error)
    XCTAssertTrue(p2.isPaged)
    XCTAssertEqual(p2.totalUnits, 3)
    XCTAssertTrue(p2.content.contains("Budget is 4.2M"))
    XCTAssertFalse(p2.content.contains("Intro text"))

    let outOfRange = WorkspaceTools.sliceDocument(
      name: "report.pdf", text: paged, pageCount: 3, startPage: 5, endPage: 6)
    XCTAssertNotNil(outOfRange.error)

    let textLines = (1...10).map { "line \($0)" }.joined(separator: "\n")
    let slice = WorkspaceTools.sliceDocument(
      name: "notes.txt", text: textLines, pageCount: 0, startPage: 3, endPage: 5)
    XCTAssertNil(slice.error)
    XCTAssertFalse(slice.isPaged)
    XCTAssertEqual(slice.start, 3)
    XCTAssertEqual(slice.end, 5)
    XCTAssertTrue(slice.content.contains("3: line 3"))
    XCTAssertTrue(slice.content.contains("5: line 5"))
  }

  func testMatchDocumentName() {
    let docs = ["Q4-Report.pdf", "sales.csv", "meeting-notes.md"]
    XCTAssertEqual(WorkspaceTools.matchDocumentName("sales.csv", among: docs, name: { $0 }), "sales.csv")
    XCTAssertEqual(WorkspaceTools.matchDocumentName("SALES.CSV", among: docs, name: { $0 }), "sales.csv")
    XCTAssertEqual(WorkspaceTools.matchDocumentName("sales", among: docs, name: { $0 }), "sales.csv")
    XCTAssertEqual(WorkspaceTools.matchDocumentName("Report", among: docs, name: { $0 }), "Q4-Report.pdf")
    XCTAssertNil(WorkspaceTools.matchDocumentName("unknown.txt", among: docs, name: { $0 }))
  }

  // MARK: - Large-context ToolBudget invariant

  func testLargeWindowAllowsFourToolCallsSafely() {
    for room in [16_384, 30_000, 60_000] {
      for thinking in [nil, 1_024, 4_096] {
        let plan = ToolBudget.plan(room: room, toolsOffered: true, thinkingBudget: thinking)
        XCTAssertEqual(plan.limits.maxCalls, 4, "room \(room)")
        let total =
          plan.outputCap
          + plan.limits.maxCalls * plan.followUpCap
          + plan.limits.maxCalls * plan.limits.maxResultTokens
        XCTAssertLessThanOrEqual(total, room, "Overflow at room \(room), thinking \(String(describing: thinking))")
      }
    }
  }

  // MARK: - AppState tool wiring & read-only metadata

  @MainActor
  func testWorkspaceToolsEndToEndWithAppState() async throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let appState = AppState(useMockEngine: true)
    appState.modelContext = context

    // Past chat to be discovered by search_past_chats.
    let pastThread = appState.newThread(in: context)
    pastThread.title = "Kitchen Remodel Budget"
    pastThread.append(ChatTurn(role: .user, text: "Our countertop quote came back at $4,800."))
    pastThread.append(ChatTurn(role: .model, text: "Noted: $4,800 for the kitchen countertops."))

    // Active chat with an attached CSV and PDF.
    let activeThread = appState.newThread(in: context)
    activeThread.title = "Active Analysis"
    appState.selectedThreadID = activeThread.id

    let pdfDoc = ExtractedDocument(
      name: "harbour.pdf", kind: .pdf, byteCount: 200,
      pages: ["Cover page for Cape Rouge.", "Page two states the harbour budget is $4.2 million."]).prepared()
    let csvDoc = ExtractedDocument(
      name: "sales.csv", kind: .text, byteCount: 200, pages: [sampleCSV]).prepared()
    appState.knowledge.add(pdfDoc, threadID: activeThread.id)
    appState.knowledge.add(csvDoc, threadID: activeThread.id)

    // Verify all P5.2 tools declare isReadOnly == true.
    XCTAssertTrue(CurrentDateTimeTool.isReadOnly)
    XCTAssertTrue(CalculatorTool.isReadOnly)
    XCTAssertTrue(WebSearchTool.isReadOnly)
    XCTAssertTrue(ConvertUnitsTool.isReadOnly)
    XCTAssertTrue(SearchFilesTool.isReadOnly)
    XCTAssertTrue(ReadDocumentPagesTool.isReadOnly)
    XCTAssertTrue(SearchPastChatsTool.isReadOnly)
    XCTAssertTrue(QueryTableOrJsonTool.isReadOnly)

    // Verify search_files
    var search = SearchFilesTool()
    search.query = "harbour budget"
    let searchOut = try await search.run() as? [String: Any]
    XCTAssertTrue((searchOut?["excerpts"] as? String ?? "").contains("4.2 million"))

    // Verify read_document_pages
    var reader = ReadDocumentPagesTool()
    reader.fileName = "harbour.pdf"
    reader.startPage = 2
    let pageOut = try await reader.run() as? [String: Any]
    XCTAssertEqual(pageOut?["start"] as? Int, 2)
    XCTAssertTrue((pageOut?["content"] as? String ?? "").contains("4.2 million"))

    // Verify query_table_or_json against attached CSV
    var tableTool = QueryTableOrJsonTool()
    tableTool.operation = "sum"
    tableTool.fileName = "sales.csv"
    tableTool.column = "revenue"
    tableTool.whereClause = "region = West"
    let tableOut = try await tableTool.run() as? [String: Any]
    XCTAssertTrue((tableOut?["result"] as? String ?? "").contains("3000.25"))

    // Verify search_past_chats finds pastThread and excludes activeThread
    var pastSearch = SearchPastChatsTool()
    pastSearch.query = "countertop quote"
    let pastOut = try await pastSearch.run() as? [String: Any]
    let pastText = pastOut?["results"] as? String ?? ""
    XCTAssertTrue(pastText.contains("Kitchen Remodel Budget"), pastText)
    XCTAssertTrue(pastText.contains("4,800"), pastText)
    XCTAssertFalse(pastText.contains("Active Analysis"))

    // Verify convert_units
    var conv = ConvertUnitsTool()
    conv.value = 100
    conv.fromUnit = "C"
    conv.toUnit = "F"
    let convOut = try await conv.run() as? [String: Any]
    XCTAssertEqual(convOut?["result"] as? Double, 212)
  }

  func testStructuredDataQueryStrictWeakOrderingOnMixedAndExtremeValues() throws {
    // Mixed numeric + alphanumeric values previously formed a 3-cycle ("2" < "10" < "15a" < "2").
    let rows = (0..<40).map { i -> String in
      switch i % 3 {
      case 0: return "r\(i),2"
      case 1: return "r\(i),10"
      default: return "r\(i),15a"
      }
    }
    let csv = "id,val\n" + rows.joined(separator: "\n")
    let asc = try StructuredDataQuery.execute(
      raw: csv, request: .init(operation: "filter", sortBy: "val", descending: false, limit: 50))
    XCTAssertEqual(asc.matchedRows, 40)
    let desc = try StructuredDataQuery.execute(
      raw: csv, request: .init(operation: "filter", sortBy: "val", descending: true, limit: 50))
    XCTAssertEqual(desc.matchedRows, 40)

    // Extreme values that overflow sum to ±Inf / NaN must not trap grouped sort.
    let extremeCSV = """
      grp,n
      A,1e308
      A,1e308
      A,-1e308
      A,-1e308
      B,42
      """
    let grouped = try StructuredDataQuery.execute(
      raw: extremeCSV, request: .init(operation: "sum", column: "n", groupBy: "grp"))
    XCTAssertEqual(grouped.matchedRows, 5)
  }
}
