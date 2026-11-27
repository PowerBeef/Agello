import Foundation
import LiteRTLMTools

// MARK: - Opt-In Photos + On-Device Vision OCR Tool (Read-Only)

/// Searches the user's Photos library by date range, favorite flag, and on-device ANE Vision OCR
/// (for receipts, whiteboards, signs, and documents), respecting `.limited` photo library access.
/// All OCR text and metadata are spotlighted inside `<untrusted_data>` (tainting `TurnSecurityContext`).
struct SearchPhotosTool: Tool {
  static let name = "search_photos"
  static let isReadOnly = true
  static let description =
    "Search Photos by date, favorites, or on-device OCR text in receipts, screenshots, and documents."

  @ToolParam(description: "Optional text to match via on-device OCR or location name.")
  var query: String? = nil

  @ToolParam(description: "Optional start date (YYYY-MM-DD).")
  var startDate: String? = nil

  @ToolParam(description: "Optional end date (YYYY-MM-DD).")
  var endDate: String? = nil

  @ToolParam(description: "Only include favorite photos (default false).")
  var favoritesOnly: Bool = false

  @ToolParam(description: "Run on-device Vision OCR to read text inside photos (default true).")
  var readText: Bool = true

  @ToolParam(description: "Max photos to return (1-8, default 5).")
  var limit: Int = 5

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let capped = max(1, min(8, limit))
    var start: Date?
    var end: Date?
    if let startDate, !startDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(startDate, endOfDay: false) else {
        return ["error": "Invalid startDate. Use YYYY-MM-DD."]
      }
      start = parsed
    }
    if let endDate, !endDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(endDate, endOfDay: true) else {
        return ["error": "Invalid endDate. Use YYYY-MM-DD."]
      }
      end = parsed
    }

    let cleanQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = await PersonalTools.activeBackend.searchPhotos(
      query: cleanQuery?.isEmpty == true ? nil : cleanQuery,
      start: start, end: end,
      favoritesOnly: favoritesOnly,
      includeOCR: readText,
      limit: capped)

    switch result {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Photos unavailable")
      return ["error": ToolOutput.text(message)]
    case .success(let matches):
      ToolActivity.record(Self.name, summary: "Searched Photos (\(matches.count) matches)")
      let sources = matches.enumerated().map { offset, item in
        let dateLabel = item.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo"
        let title = item.locationName.map { "Photo · \($0) · \(dateLabel)" } ?? "Photo · \(dateLabel)"
        let snippet = item.ocrText.map { String($0.prefix(200)) } ?? "\(item.width)×\(item.height)"
        return SourceRecord(index: WebSourcesRecorder.nextIndex + offset, title: title, url: nil, snippet: snippet)
      }
      if !sources.isEmpty { WebSourcesRecorder.record(sources) }
      let formatted = PersonalToolsLogic.formatPhotos(matches)
      return [
        "count": matches.count,
        "photos": UntrustedContext.wrapFitted(formatted, source: "photo_ocr", limits: limits),
      ]
    }
  }
}

// MARK: - Outbound User-Allowlisted Shortcuts Bridge Tool (Mutating / External)

/// Runs a user-registered Apple Shortcut via `shortcuts://x-callback-url/run-shortcut`.
/// Enforces a 4-layer security barrier:
/// 1. Strict `AutomationRegistry` allowlist check BEFORE any confirmation UI.
/// 2. `.external` `ToolConfirmationCard` displaying exact Shortcut name, summary, verbatim input,
///    and any `TurnSecurityContext` untrusted-source taint warning.
/// 3. Cryptographic 256-bit CSPRNG `nonce` + single-use request UUID + 120 s TTL via
///    `ShortcutCallbackBroker`, preserving KV cache across background suspension with `GPUGate` closed.
/// 4. `<untrusted_data>` spotlighting on returned Shortcut output + `AutomationHandoffCard`.
struct RunShortcutTool: Tool {
  static let name = "run_shortcut"
  static let isReadOnly = false
  static let description =
    "Run a user-allowlisted Apple Shortcut by id or exact name (always confirms first; only registered shortcuts allowed)."

  @ToolParam(description: "Registered shortcut id or exact name from the user's allowlist.")
  var shortcutId: String

  @ToolParam(description: "Optional text or JSON payload passed as Shortcut Input.")
  var input: String? = nil

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let cleanID = shortcutId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let shortcut = AutomationRegistry.shared.shortcut(matching: cleanID) else {
      ToolActivity.record(Self.name, summary: "Blocked unregistered shortcut “\(cleanID)”")
      return [
        "executed": false,
        "status": "not_allowlisted",
        "error": "Shortcut '\(ToolOutput.text(cleanID, maxChars: 80))' is not in the user's allowlist. Ask the user to add it in Settings > Automations & Shortcuts.",
      ]
    }

    let cleanInput = input?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveInput = (shortcut.inputMode == .none || cleanInput?.isEmpty != false) ? nil : cleanInput
    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "shortcut", value: shortcut.name)
    ]
    if !shortcut.summary.isEmpty {
      params.append(.init(name: "action", value: shortcut.summary))
    }
    if let effectiveInput {
      params.append(.init(name: "input", value: String(effectiveInput.prefix(300))))
    }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Run Shortcut"),
      summary: "Launch “\(shortcut.name)” in Apple Shortcuts.",
      parameters: params,
      risk: .external)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled shortcut “\(shortcut.name)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    let callback = await ShortcutCallbackBroker.shared.runShortcut(
      name: shortcut.name, input: effectiveInput)

    let cardState: AutomationHandoffCard.State
    let statusString: String
    switch callback.status {
    case .ok:
      cardState = .completed
      statusString = "completed"
    case .error:
      cardState = .failed
      statusString = "failed"
    case .cancel:
      cardState = .cancelled
      statusString = "cancelled"
    case .timedOut:
      cardState = .cancelled
      statusString = "cancelled_or_timed_out"
    }

    let outputSummary = callback.output?.trimmingCharacters(in: .whitespacesAndNewlines)
    ToolActivity.record(Self.name, summary: "Shortcut “\(shortcut.name)”: \(statusString)")
    ToolCardRecorder.record(
      .automationHandoff(
        AutomationHandoffCard(
          shortcutID: shortcut.id,
          shortcutName: shortcut.name,
          inputSummary: effectiveInput.map { String($0.prefix(160)) },
          state: cardState,
          resultSummary: (outputSummary?.isEmpty == false ? outputSummary : callback.errorMessage)
            .map { String($0.prefix(240)) },
          callbackRequestID: callback.requestID.uuidString)))

    var receipt: [String: Any] = [
      "executed": callback.status == .ok,
      "status": statusString,
      "shortcut": ToolOutput.text(shortcut.name, maxChars: 80),
    ]
    if let outputSummary, !outputSummary.isEmpty {
      receipt["result"] = UntrustedContext.wrapFitted(
        outputSummary, source: "shortcut:\(shortcut.name)", limits: limits)
    }
    if let err = callback.errorMessage, !err.isEmpty {
      receipt["error"] = ToolOutput.text(err, maxChars: 240)
    }
    return receipt
  }
}

// MARK: - Multi-Step Plan Confirmation Planner (Zero TOCTOU)

/// Builds a grouped ``ToolConfirmationRequest`` (`PlanConfirmationCard`) when a single model round
/// emits multiple mutating (`isReadOnly == false`) tool calls. Pre-validates allowlists and
/// performs authoritative EventKit/AlarmKit lookups before presenting the card, then issues
/// single-use per-step grants ONLY for the exact user-checked step indices.
enum BatchConfirmationPlanner {
  static func confirmBatch(_ invocations: [PendingToolInvocation]) async -> BatchConfirmationOutcome? {
    guard invocations.count > 1 else { return nil }
    var steps: [ToolConfirmationRequest.Step] = []
    var validIndices: Set<Int> = []
    for invocation in invocations {
      let args =
        (try? JSONSerialization.jsonObject(with: invocation.argumentsJSON)) as? [String: Any] ?? [:]
      if let step = await buildStep(index: invocation.index, name: invocation.name, args: args) {
        steps.append(step)
        validIndices.insert(invocation.index)
      }
    }
    // If fewer than 2 valid confirmable actions remain (e.g. an invalid ID or unregistered shortcut),
    // fall back to individual tool paths so each invalid call returns its exact error pre-confirm.
    guard steps.count >= 2 else { return nil }

    let highestRisk: ToolConfirmationRequest.RiskTier
    if steps.contains(where: { $0.risk == .destructive }) {
      highestRisk = .destructive
    } else if steps.contains(where: { $0.risk == .external }) {
      highestRisk = .external
    } else {
      highestRisk = .standard
    }

    let request = ToolConfirmationRequest(
      toolName: "action_plan",
      title: String(localized: "Review \(steps.count) actions"),
      summary: String(localized: "Choose which actions Agello should run."),
      parameters: [],
      risk: highestRisk,
      steps: steps)

    let decision = await ToolConfirmationGate.confirm(request)
    let approved: Set<Int>
    switch decision {
    case .approved:
      approved = validIndices
    case .approvedSteps(let chosen):
      approved = chosen.intersection(validIndices)
    case .denied:
      approved = []
    }
    let skippedByUser = validIndices.subtracting(approved)

    ToolConfirmationGate.clearBatchGrants()
    for step in steps where approved.contains(step.index) {
      ToolConfirmationGate.grantBatchStep(toolName: step.toolName, risk: step.risk)
    }
    return BatchConfirmationOutcome(approved: approved, skippedByUser: skippedByUser)
  }

  private static func buildStep(
    index: Int, name: String, args: [String: Any]
  ) async -> ToolConfirmationRequest.Step? {
    switch name {
    case ManageCalendarEventTool.name:
      return await buildCalendarStep(index: index, args: args)
    case ManageReminderTool.name:
      return await buildReminderStep(index: index, args: args)
    case ManageAlarmTool.name:
      return await buildAlarmStep(index: index, args: args)
    case PrepareMessageTool.name:
      return buildMessageStep(index: index, args: args)
    case RunShortcutTool.name:
      return buildShortcutStep(index: index, args: args)
    default:
      return nil
    }
  }

  private static func buildCalendarStep(
    index: Int, args: [String: Any]
  ) async -> ToolConfirmationRequest.Step? {
    let action = (args["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch action {
    case "create":
      let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let start = args["start_date"] as? String ?? ""
      let end = args["end_date"] as? String ?? ""
      guard !title.isEmpty,
        let parsedStart = PersonalToolsLogic.parseDate(start, endOfDay: false),
        let parsedEnd = PersonalToolsLogic.parseDate(end, endOfDay: false),
        parsedEnd > parsedStart
      else { return nil }
      var params: [ToolConfirmationRequest.Parameter] = [
        .init(name: "title", value: title),
        .init(
          name: "time",
          value: "\(PersonalToolsLogic.formatISO(parsedStart)) – \(PersonalToolsLogic.formatISO(parsedEnd))"),
      ]
      if let loc = args["location"] as? String, !loc.isEmpty { params.append(.init(name: "location", value: loc)) }
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageCalendarEventTool.name,
        title: String(localized: "Create calendar event"),
        summary: "Add “\(title)” to Calendar.", parameters: params, risk: .standard)
    case "update", "delete":
      guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.isEmpty,
        case .success(let existing) = await PersonalTools.activeBackend.fetchCalendarEvent(identifier: id)
      else { return nil }
      let isDelete = action == "delete"
      if !isDelete {
        var newStart: Date?
        var newEnd: Date?
        if let rawStart = args["start_date"] as? String, !rawStart.isEmpty {
          guard let parsed = PersonalToolsLogic.parseDate(rawStart, endOfDay: false) else { return nil }
          newStart = parsed
        }
        if let rawEnd = args["end_date"] as? String, !rawEnd.isEmpty {
          guard let parsed = PersonalToolsLogic.parseDate(rawEnd, endOfDay: false) else { return nil }
          newEnd = parsed
        }
        let effectiveStart = newStart ?? existing.startDate
        let effectiveEnd = newEnd ?? existing.endDate
        guard effectiveEnd > effectiveStart else { return nil }
      }
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageCalendarEventTool.name,
        title: isDelete ? String(localized: "Delete calendar event") : String(localized: "Update calendar event"),
        summary: isDelete
          ? "Permanently remove “\(existing.title)” from Calendar."
          : "Update “\(existing.title)” in Calendar.",
        parameters: [
          .init(name: "event", value: existing.title),
          .init(name: "start", value: PersonalToolsLogic.formatISO(existing.startDate)),
        ],
        risk: isDelete ? .destructive : .standard)
    default:
      return nil
    }
  }

  private static func buildReminderStep(
    index: Int, args: [String: Any]
  ) async -> ToolConfirmationRequest.Step? {
    let action = (args["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch action {
    case "create":
      let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }
      var params: [ToolConfirmationRequest.Parameter] = [.init(name: "title", value: title)]
      if let due = (args["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !due.isEmpty
      {
        guard let parsed = PersonalToolsLogic.parseDate(due, endOfDay: false) else { return nil }
        params.append(.init(name: "due", value: PersonalToolsLogic.formatISO(parsed)))
      }
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageReminderTool.name,
        title: String(localized: "Create reminder"),
        summary: "Add “\(title)” to Reminders.", parameters: params, risk: .standard)
    case "complete", "reopen", "update", "delete":
      guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.isEmpty,
        case .success(let existing) = await PersonalTools.activeBackend.fetchReminder(identifier: id)
      else { return nil }
      if action == "update",
        let due = (args["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !due.isEmpty,
        PersonalToolsLogic.parseDate(due, endOfDay: false) == nil
      {
        return nil
      }
      let isDelete = action == "delete"
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageReminderTool.name,
        title: isDelete ? String(localized: "Delete reminder") : String(localized: "Update reminder"),
        summary: isDelete
          ? "Permanently remove “\(existing.title)” from Reminders."
          : "\(action.capitalized) “\(existing.title)” in Reminders.",
        parameters: [.init(name: "reminder", value: existing.title)],
        risk: isDelete ? .destructive : .standard)
    default:
      return nil
    }
  }

  private static func buildAlarmStep(
    index: Int, args: [String: Any]
  ) async -> ToolConfirmationRequest.Step? {
    let action = (args["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch action {
    case "set_timer":
      let label = (args["label"] as? String) ?? "Timer"
      guard let secs = parseDouble(args["duration_seconds"]),
        secs.isFinite, secs >= 5, secs <= 24 * 3_600
      else { return nil }
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageAlarmTool.name,
        title: String(localized: "Start timer"),
        summary: "Start \(PersonalToolsLogic.formatDuration(secs)) timer “\(label)”.",
        parameters: [.init(name: "label", value: label)], risk: .standard)
    case "set_alarm":
      let label = (args["label"] as? String) ?? "Alarm"
      guard let h = parseInt(args["hour"]),
        let m = parseInt(args["minute"]),
        (0...23).contains(h), (0...59).contains(m)
      else { return nil }
      let timeText = String(format: "%02d:%02d", h, m)
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageAlarmTool.name,
        title: String(localized: "Set alarm"),
        summary: "Schedule alarm “\(label)” for \(timeText).",
        parameters: [.init(name: "time", value: timeText)], risk: .standard)
    case "cancel":
      guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.isEmpty,
        case .success(let all) = await PersonalTools.activeBackend.listAlarms(),
        let existing = all.first(where: { $0.alarmID == id })
      else { return nil }
      return ToolConfirmationRequest.Step(
        index: index, toolName: ManageAlarmTool.name,
        title: String(localized: "Cancel \(existing.kind.rawValue)"),
        summary: "Cancel “\(existing.label)”.",
        parameters: [.init(name: "label", value: existing.label)], risk: .destructive)
    default:
      return nil
    }
  }

  private static func parseDouble(_ raw: Any?) -> Double? {
    if let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
      let d = num.doubleValue
      return d.isFinite ? d : nil
    }
    if let str = raw as? String,
      let d = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)),
      d.isFinite
    {
      return d
    }
    return nil
  }

  private static func parseInt(_ raw: Any?) -> Int? {
    if let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
      if !CFNumberIsFloatType(num as CFNumber) {
        return Int(exactly: num)
      }
      return Int(exactly: num.doubleValue)
    }
    if let str = raw as? String {
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      if let i = Int(trimmed) { return i }
      if let d = Double(trimmed) { return Int(exactly: d) }
    }
    return nil
  }

  private static func buildMessageStep(
    index: Int, args: [String: Any]
  ) -> ToolConfirmationRequest.Step? {
    let channel = (args["channel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let cleanRecipients = ((args["recipients"] as? [String]) ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let body = (args["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard channel == "sms" || channel == "email", !cleanRecipients.isEmpty, !body.isEmpty else {
      return nil
    }
    let cleanSubject = (args["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let unverified = TurnContactRoster.unverifiedRecipients(from: cleanRecipients)
    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "channel", value: channel == "sms" ? "SMS" : "Email"),
      .init(name: "to", value: cleanRecipients.joined(separator: ", ")),
    ]
    if !unverified.isEmpty {
      params.append(
        .init(
          name: "warning",
          value: "Unverified recipient (not in Contacts): \(unverified.joined(separator: ", "))"))
    }
    if let cleanSubject, !cleanSubject.isEmpty {
      params.append(.init(name: "subject", value: cleanSubject))
    }
    params.append(.init(name: "body", value: String(body.prefix(120))))
    return ToolConfirmationRequest.Step(
      index: index, toolName: PrepareMessageTool.name,
      title: channel == "email" ? String(localized: "Draft email") : String(localized: "Draft text message"),
      summary: "Prepare a draft for \(cleanRecipients.joined(separator: ", ")).",
      parameters: params,
      risk: .standard)
  }

  private static func buildShortcutStep(
    index: Int, args: [String: Any]
  ) -> ToolConfirmationRequest.Step? {
    let rawID = (args["shortcut_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let shortcut = AutomationRegistry.shared.shortcut(matching: rawID) else { return nil }
    var params: [ToolConfirmationRequest.Parameter] = [.init(name: "shortcut", value: shortcut.name)]
    if let input = args["input"] as? String, !input.isEmpty {
      params.append(.init(name: "input", value: String(input.prefix(140))))
    }
    return ToolConfirmationRequest.Step(
      index: index, toolName: RunShortcutTool.name,
      title: String(localized: "Run Shortcut"),
      summary: "Launch “\(shortcut.name)” in Apple Shortcuts.",
      parameters: params, risk: .external)
  }
}
