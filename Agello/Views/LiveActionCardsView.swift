import SwiftUI

// MARK: - Weather Card (Apple WeatherKit)

struct WeatherCardView: View {
  let card: WeatherCard
  var isCompact = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        TintTile(symbol: card.conditionSymbol, tint: Theme.Brand.glacier)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.locationName)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
            .lineLimit(1)
          Text(card.condition.capitalized)
            .font(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .lineLimit(1)
          let details = [
            card.feelsLike.map { "Feels like \($0)" },
            card.high.flatMap { hi in card.low.map { lo in "H:\(hi) L:\(lo)" } },
          ].compactMap { $0 }.joined(separator: " · ")
          if !details.isEmpty {
            Text(details)
              .font(.caption2)
              .foregroundStyle(Theme.Text.tertiary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(card.temperature)
          .font(.system(.title2, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.Brand.glacier)
      }

      if !card.alerts.isEmpty {
        ForEach(card.alerts.prefix(2)) { alert in
          HStack(alignment: .top, spacing: Theme.Spacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(Theme.Status.guarded)
            Text(alert.summary)
              .font(.caption.weight(.medium))
              .foregroundStyle(Theme.Status.guarded)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(Theme.Spacing.sm)
          .surfaceCard(
            radius: Theme.Radius.row, fill: Theme.Status.guarded.opacity(0.12),
            stroke: Theme.Status.guarded.opacity(0.35))
        }
      }

      if !isCompact {
        let meta = [
          card.humidityPercent.map { "Humidity \($0)%" },
          card.windSpeed.map { "Wind \($0)" },
        ].compactMap { $0 }
        if !meta.isEmpty {
          WrapFlowLayout(horizontalSpacing: Theme.Spacing.tight, verticalSpacing: Theme.Spacing.xs) {
            ForEach(meta, id: \.self) { label in
              Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background { QuietBackground(shape: Capsule()) }
            }
          }
        }

        if !card.daily.isEmpty {
          VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(card.daily.prefix(4)) { day in
              HStack(spacing: Theme.Spacing.sm) {
                Text(day.label)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(Theme.Text.secondary)
                  .frame(width: 44, alignment: .leading)
                Image(systemName: day.symbolName)
                  .font(.caption)
                  .foregroundStyle(Theme.Brand.glacier)
                  .frame(width: 20)
                if day.precipitationPercent >= 15 {
                  Text("\(day.precipitationPercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Brand.teal)
                }
                Spacer()
                Text("\(day.low) – \(day.high)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(Theme.Text.primary)
              }
            }
          }
          .padding(Theme.Spacing.sm)
          .surfaceCard(radius: Theme.Radius.row, fill: Theme.Surface.card)
        }
      }

      WeatherAttributionMark()
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.weather")
  }
}

// MARK: - Alarm / Timer Card (iOS 27 AlarmKit)

struct AlarmCardView: View {
  let card: AlarmCard
  @State private var state: AlarmCard.State
  @State private var isUpdating = false

  init(card: AlarmCard) {
    self.card = card
    _state = State(initialValue: card.state)
  }

  private var symbol: String {
    card.kind == .timer ? "timer" : "alarm.fill"
  }

  private var stateBadge: (text: String, tone: Color) {
    switch state {
    case .scheduled: (String(localized: "Scheduled"), Theme.Status.healthy)
    case .countdown: (String(localized: "Running"), Theme.Brand.gold)
    case .paused: (String(localized: "Paused"), Theme.Status.guarded)
    case .alerting: (String(localized: "Alerting"), Theme.Status.critical)
    case .cancelled: (String(localized: "Cancelled"), Theme.Text.tertiary)
    }
  }

  private var scheduleLine: String {
    if let hour = card.hour, let minute = card.minute {
      let time = String(format: "%02d:%02d", hour, minute)
      return card.weekdays.isEmpty ? time : "\(time) · \(card.weekdays.joined(separator: ", ").capitalized)"
    }
    if let secs = card.durationSeconds {
      return PersonalToolsLogic.formatDuration(secs)
    }
    return card.kind == .timer ? String(localized: "Timer") : String(localized: "Alarm")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        TintTile(symbol: symbol, tint: Theme.Brand.gold)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.label)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(state == .cancelled ? Theme.Text.tertiary : Theme.Text.primary)
            .strikethrough(state == .cancelled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if card.kind == .timer, state == .countdown, let fireDate = card.fireDate, fireDate > .now {
            Text(fireDate, style: .timer)
              .font(.system(.callout, weight: .semibold).monospacedDigit())
              .foregroundStyle(Theme.Brand.gold)
          } else {
            Text(scheduleLine)
              .font(.caption.monospacedDigit())
              .foregroundStyle(Theme.Text.secondary)
          }
        }
        StatusBadge(text: stateBadge.text, tone: stateBadge.tone)
      }

      if state != .cancelled {
        WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
          if card.kind == .timer, state == .countdown {
            Button {
              performAction(.pause)
            } label: {
              Label("Pause", systemImage: "pause.fill")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(minHeight: 36)
                .background { QuietBackground(shape: Capsule()) }
                .frame(minHeight: Theme.Size.target)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .accessibilityIdentifier("actionCard.alarm.pause")
          } else if card.kind == .timer, state == .paused {
            Button {
              performAction(.resume)
            } label: {
              Label("Resume", systemImage: "play.fill")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(minHeight: 36)
                .background { LitTintBackground(shape: Capsule(), tint: Theme.Brand.teal, strength: .pill) }
                .frame(minHeight: Theme.Size.target)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .accessibilityIdentifier("actionCard.alarm.resume")
          }

          Button {
            performAction(.cancel)
          } label: {
            Label("Cancel", systemImage: "xmark")
              .font(.system(.footnote, weight: .medium))
              .foregroundStyle(Theme.Status.critical)
              .padding(.horizontal, Theme.Spacing.md)
              .frame(minHeight: 36)
              .background { QuietBackground(shape: Capsule()) }
              .frame(minHeight: Theme.Size.target)
          }
          .buttonStyle(.plain)
          .disabled(isUpdating)
          .accessibilityIdentifier("actionCard.alarm.cancel")
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.alarm")
  }

  private enum AlarmAction { case pause, resume, cancel }

  private func performAction(_ action: AlarmAction) {
    isUpdating = true
    Task {
      defer { isUpdating = false }
      let backend = PersonalTools.activeBackend
      let result: PersonalToolResult<AlarmSummary>
      switch action {
      case .pause: result = await backend.pauseAlarm(identifier: card.alarmID)
      case .resume: result = await backend.resumeAlarm(identifier: card.alarmID)
      case .cancel: result = await backend.cancelAlarm(identifier: card.alarmID)
      }
      if case .success(let updated) = result {
        state = updated.state
        Haptics.complete()
      }
    }
  }
}

// MARK: - Automation Handoff Card (Shortcuts Bridge)

struct AutomationHandoffCardView: View {
  let card: AutomationHandoffCard

  private var statusBadge: (text: String, tone: Color) {
    switch card.state {
    case .readyToRun: (String(localized: "Ready"), Theme.Brand.glacier)
    case .completed: (String(localized: "Completed"), Theme.Status.healthy)
    case .failed: (String(localized: "Failed"), Theme.Status.critical)
    case .cancelled: (String(localized: "Cancelled"), Theme.Status.guarded)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        TintTile(symbol: "bolt.fill", tint: Theme.Brand.glacier)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.shortcutName)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let input = card.inputSummary, !input.isEmpty {
            Text("Input: \(input)")
              .font(.caption)
              .foregroundStyle(Theme.Text.tertiary)
              .lineLimit(2)
          }
        }
        StatusBadge(text: statusBadge.text, tone: statusBadge.tone)
      }

      if let result = card.resultSummary, !result.isEmpty {
        Text(result)
          .font(.caption)
          .foregroundStyle(Theme.Text.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Theme.Spacing.sm)
          .surfaceCard(radius: Theme.Radius.row)
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.automation")
  }
}
