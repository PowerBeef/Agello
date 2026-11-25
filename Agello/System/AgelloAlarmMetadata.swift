import AlarmKit
import AppIntents
import Foundation

/// Shared AlarmKit metadata compiled into both the app and `AgelloWidgets` so Live Activities
/// and Dynamic Island presentations show the user's timer or alarm label.
struct AgelloAlarmMetadata: AlarmMetadata {
  var label: String
  var kind: String
  var createdAt: Date

  init(label: String, kind: String, createdAt: Date = .now) {
    self.label = label
    self.kind = kind
    self.createdAt = createdAt
  }
}

/// Stops an alerting or active Agello AlarmKit timer/alarm directly from the Lock Screen or Dynamic Island.
struct StopAgelloAlarmIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop Agello Alarm"
  static let description = IntentDescription("Stop an active Agello timer or alarm.")

  @Parameter(title: "Alarm ID")
  var alarmID: String

  init() { self.alarmID = "" }

  init(alarmID: String) {
    self.alarmID = alarmID
  }

  func perform() async throws -> some IntentResult {
    if let uuid = UUID(uuidString: alarmID) {
      try? AlarmManager.shared.stop(id: uuid)
      try? AlarmManager.shared.cancel(id: uuid)
    }
    return .result()
  }
}

/// Pauses a running Agello countdown timer directly from its Live Activity.
struct PauseAgelloAlarmIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Pause Agello Timer"
  static let description = IntentDescription("Pause a running Agello countdown timer.")

  @Parameter(title: "Alarm ID")
  var alarmID: String

  init() { self.alarmID = "" }

  init(alarmID: String) {
    self.alarmID = alarmID
  }

  func perform() async throws -> some IntentResult {
    if let uuid = UUID(uuidString: alarmID) {
      try? AlarmManager.shared.pause(id: uuid)
    }
    return .result()
  }
}

/// Resumes a paused Agello countdown timer directly from its Live Activity.
struct ResumeAgelloAlarmIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Resume Agello Timer"
  static let description = IntentDescription("Resume a paused Agello countdown timer.")

  @Parameter(title: "Alarm ID")
  var alarmID: String

  init() { self.alarmID = "" }

  init(alarmID: String) {
    self.alarmID = alarmID
  }

  func perform() async throws -> some IntentResult {
    if let uuid = UUID(uuidString: alarmID) {
      try? AlarmManager.shared.resume(id: uuid)
    }
    return .result()
  }
}
