import Foundation

/// Pure progress & eligibility math for ``BackgroundWork`` continued processing Live Activities
/// (multi-document 64K synthesis, web research, and multi-step Think tool chains).
enum BackgroundWorkPlan {
  /// Snapshot of what the Live Activity currently shows.
  struct ProgressState: Equatable, Sendable {
    var title: String
    var subtitle: String
    var completedUnits: Int64
    var completedSteps: Int
    var totalSteps: Int
  }

  /// Plain text chat stops immediately when backgrounded; only long document synthesis,
  /// multi-document work, web research, or multi-step agentic tool loops request continued work.
  static func shouldUseContinuedTask(
    documentCount: Int, wantsSummary: Bool, webSearch: Bool, multiStepTool: Bool
  ) -> Bool {
    (documentCount > 0 && wantsSummary) || documentCount > 1 || webSearch || multiStepTool
  }

  /// Maps multi-document section reading smoothly onto `0...80` units, leaving `80...100` for
  /// synthesizing the final answer.
  static func documentSectionUnits(
    documentIndex: Int, documentCount: Int, sectionCompleted: Int, sectionTotal: Int
  ) -> Int64 {
    guard documentCount > 0, sectionTotal > 0 else { return 0 }
    let clampedDoc = min(max(documentIndex, 0), documentCount - 1)
    let clampedSection = min(max(sectionCompleted, 0), sectionTotal)
    let fraction = (Double(clampedDoc) + Double(clampedSection) / Double(sectionTotal)) / Double(documentCount)
    return Int64(min(80, max(0, Int((fraction * 80.0).rounded()))))
  }

  /// Maps discrete agentic/research steps onto `0...ceiling` units.
  static func stepUnits(completed: Int, total: Int, ceiling: Int = 80) -> Int64 {
    guard total > 0, ceiling > 0 else { return 0 }
    let clamped = min(max(completed, 0), total)
    return Int64(min(ceiling, clamped * ceiling / total))
  }

  /// Monotonically advances progress into the final streaming range (`currentUnits...95`) as
  /// answer characters arrive, without jumping backwards after a preparation phase.
  static func replyUnits(
    characters: Int, currentUnits: Int64, expectedCharacters: Double = 1_500.0
  ) -> Int64 {
    guard expectedCharacters > 0 else { return min(95, max(currentUnits, 10)) }
    let clampedChars = max(0, characters)
    let base = Double(max(currentUnits, 10))
    let remaining = max(0.0, 95.0 - base)
    let progress = min(1.0, Double(clampedChars) / expectedCharacters)
    let target = Int64((base + remaining * progress).rounded())
    return min(95, max(currentUnits, target))
  }

  /// Human-readable subtitle for single- and multi-document section reading.
  static func documentSubtitle(
    name: String, documentIndex: Int, documentCount: Int, section: Int, totalSections: Int
  ) -> String {
    let part = min(max(section, 1), max(totalSections, 1))
    if documentCount > 1 {
      return "Document \(documentIndex + 1) of \(documentCount) · \(name) · part \(part) of \(totalSections)"
    }
    return "Reading \(name) · part \(part) of \(totalSections)"
  }
}
