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
          let detailsURL = NativeActionURLs.website(alert.detailsURL)
          let row = HStack(alignment: .top, spacing: Theme.Spacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(Theme.Status.guarded)
              .accessibilityHidden(true)
            Text(alert.summary)
              .font(.caption.weight(.medium))
              .foregroundStyle(Theme.Status.guarded)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
            if detailsURL != nil {
              Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.Status.guarded.opacity(0.85))
                .accessibilityHidden(true)
            }
          }
          .padding(Theme.Spacing.sm)
          .surfaceCard(
            radius: Theme.Radius.row, fill: Theme.Status.guarded.opacity(0.12),
            stroke: Theme.Status.guarded.opacity(0.35))
          .contentShape(.rect)

          if let detailsURL {
            Link(destination: detailsURL) {
              row
            }
            .buttonStyle(ActionCardPressStyle())
            .accessibilityLabel("\(alert.summary). Open alert details")
            .accessibilityIdentifier("actionCard.weather.alertLink")
          } else {
            row
          }
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
  var onUpdate: ((AlarmCard) -> Void)? = nil

  @Environment(\.scenePhase) private var scenePhase
  @State private var state: AlarmCard.State
  @State private var fireDate: Date?
  @State private var durationSeconds: Double?
  @State private var isUpdating = false
  @State private var activeAction: AlarmAction?
  @State private var errorMessage: String?

  init(card: AlarmCard, onUpdate: ((AlarmCard) -> Void)? = nil) {
    self.card = card
    self.onUpdate = onUpdate
    _state = State(initialValue: card.state)
    _fireDate = State(initialValue: card.fireDate)
    _durationSeconds = State(initialValue: card.durationSeconds)
  }

  private var symbol: String {
    card.kind == .timer ? "timer" : "alarm.fill"
  }

  private func stateBadge(isExpired: Bool) -> (text: String, tone: Color) {
    if isExpired {
      return (String(localized: "Done"), Theme.Status.healthy)
    }
    switch state {
    case .scheduled: return (String(localized: "Scheduled"), Theme.Status.healthy)
    case .countdown: return (String(localized: "Running"), Theme.Brand.gold)
    case .paused: return (String(localized: "Paused"), Theme.Status.guarded)
    case .alerting: return (String(localized: "Alerting"), Theme.Status.critical)
    case .cancelled: return (String(localized: "Cancelled"), Theme.Text.tertiary)
    }
  }

  private var scheduleLine: String {
    if let hour = card.hour, let minute = card.minute {
      let time = Self.formatAlarmTime(hour: hour, minute: minute)
      return card.weekdays.isEmpty ? time : "\(time) · \(card.weekdays.joined(separator: ", ").capitalized)"
    }
    if let secs = durationSeconds {
      return PersonalToolsLogic.formatDuration(secs)
    }
    return card.kind == .timer ? String(localized: "Timer") : String(localized: "Alarm")
  }

  private var timelineDates: [Date] {
    guard card.kind == .timer, state == .countdown, let target = fireDate else { return [] }
    return [target]
  }

  var body: some View {
    TimelineView(.explicit(timelineDates)) { context in
      let isExpired =
        card.kind == .timer && state == .countdown
        && (fireDate.map { context.date >= $0 } ?? false)
      let badge = stateBadge(isExpired: isExpired)

      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
          TintTile(symbol: symbol, tint: Theme.Brand.gold)
          VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(card.label)
              .font(.system(.subheadline, weight: .semibold))
              .foregroundStyle(state == .cancelled ? Theme.Text.tertiary : Theme.Text.primary)
              .strikethrough(state == .cancelled)
              .frame(maxWidth: .infinity, alignment: .leading)
            if card.kind == .timer, state == .countdown, let target = fireDate, !isExpired {
              Text(target, style: .timer)
                .font(.system(.callout, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Brand.gold)
                .contentTransition(.numericText(countsDown: true))
            } else if isExpired {
              Text(String(localized: "Timer finished"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Text.secondary)
            } else {
              Text(scheduleLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Text.secondary)
            }
          }
          StatusBadge(text: badge.text, tone: badge.tone)
        }

        if let errorMessage, !errorMessage.isEmpty {
          Label(errorMessage, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(Theme.Status.critical)
            .accessibilityIdentifier("actionCard.alarm.error")
        }

        if state != .cancelled, !isExpired {
          WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
            if card.kind == .timer, state == .countdown {
              Button {
                Haptics.selection()
                performAction(.pause)
              } label: {
                alarmPillLabel(
                  title: String(localized: "Pause"),
                  symbol: "pause.fill",
                  foreground: Theme.Text.secondary,
                  isBusy: activeAction == .pause,
                  isPrimary: false)
              }
              .buttonStyle(ActionCardPressStyle())
              .disabled(isUpdating)
              .accessibilityIdentifier("actionCard.alarm.pause")
            } else if card.kind == .timer, state == .paused {
              Button {
                Haptics.selection()
                performAction(.resume)
              } label: {
                alarmPillLabel(
                  title: String(localized: "Resume"),
                  symbol: "play.fill",
                  foreground: Theme.Text.primary,
                  isBusy: activeAction == .resume,
                  isPrimary: true)
              }
              .buttonStyle(ActionCardPressStyle())
              .disabled(isUpdating)
              .accessibilityIdentifier("actionCard.alarm.resume")
            }

            Button {
              Haptics.selection()
              performAction(.cancel)
            } label: {
              alarmPillLabel(
                title: state == .alerting ? String(localized: "Stop") : String(localized: "Cancel"),
                symbol: "xmark",
                foreground: Theme.Status.critical,
                isBusy: activeAction == .cancel,
                isPrimary: false)
            }
            .buttonStyle(ActionCardPressStyle())
            .disabled(isUpdating)
            .accessibilityIdentifier("actionCard.alarm.cancel")
          }
        }
      }
      .appAnimation(Theme.Motion.stateChange, value: state)
      .onChange(of: isExpired) { _, expired in
        if expired {
          Task { await syncWithAlarmManager() }
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.alarm")
    .task(id: card.alarmID) {
      await syncWithAlarmManager()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await syncWithAlarmManager() }
      }
    }
    .onChange(of: card) { _, latest in
      state = latest.state
      fireDate = latest.fireDate
      durationSeconds = latest.durationSeconds
    }
  }

  private enum AlarmAction: Equatable { case pause, resume, cancel }

  private func alarmPillLabel(
    title: String, symbol: String, foreground: Color, isBusy: Bool, isPrimary: Bool
  ) -> some View {
    HStack(spacing: Theme.Spacing.tight) {
      if isBusy {
        ProgressView()
          .controlSize(.mini)
          .tint(foreground)
      } else {
        Image(systemName: symbol)
      }
      Text(title)
    }
    .font(.system(.footnote, weight: isPrimary ? .semibold : .medium))
    .foregroundStyle(foreground)
    .lineLimit(1)
    .minimumScaleFactor(0.85)
    .padding(.horizontal, Theme.Spacing.md)
    .frame(minHeight: 36)
    .background {
      if isPrimary {
        LitTintBackground(shape: Capsule(), tint: Theme.Brand.teal, isEnabled: !isUpdating, strength: .pill)
      } else {
        QuietBackground(shape: Capsule())
      }
    }
    .frame(minHeight: Theme.Size.target)
    .contentShape(.rect)
  }

  private func performAction(_ action: AlarmAction) {
    guard !isUpdating else { return }
    errorMessage = nil
    isUpdating = true
    activeAction = action
    Task {
      defer {
        isUpdating = false
        activeAction = nil
      }
      let backend = PersonalTools.activeBackend
      let result: PersonalToolResult<AlarmSummary>
      switch action {
      case .pause: result = await backend.pauseAlarm(identifier: card.alarmID)
      case .resume: result = await backend.resumeAlarm(identifier: card.alarmID)
      case .cancel: result = await backend.cancelAlarm(identifier: card.alarmID)
      }
      switch result {
      case .success(let updated):
        withAppAnimation(Theme.Motion.stateChange) {
          state = updated.state
          fireDate = updated.fireDate
          if let updatedDuration = updated.durationSeconds {
            durationSeconds = updatedDuration
          }
        }
        emitUpdate()
        Haptics.complete()
      case .error(let message):
        errorMessage = message
        Haptics.error()
      }
    }
  }

  private func syncWithAlarmManager() async {
    guard state != .cancelled else { return }
    guard case .success(let alarms) = await PersonalTools.activeBackend.listAlarms() else { return }
    if let live = alarms.first(where: { $0.alarmID == card.alarmID }) {
      let nextFire = live.fireDate ?? (live.state == .paused ? nil : fireDate)
      let nextDuration = live.durationSeconds ?? durationSeconds
      let changed = state != live.state || fireDate != nextFire || durationSeconds != nextDuration
      withAppAnimation(Theme.Motion.stateChange) {
        state = live.state
        fireDate = nextFire
        durationSeconds = nextDuration
      }
      if changed { emitUpdate() }
      return
    }
    // Alarm/timer is no longer scheduled in AlarmKit. Keep expired timers showing "Done",
    // while reconciling cancelled or dismissed entries so stale buttons don't persist.
    let expiredTimer = card.kind == .timer && state == .countdown && (fireDate.map { $0 <= .now } ?? false)
    if !expiredTimer {
      withAppAnimation(Theme.Motion.stateChange) {
        state = .cancelled
        fireDate = nil
      }
      emitUpdate()
    }
  }

  private func emitUpdate() {
    var updated = card
    updated.state = state
    updated.fireDate = fireDate
    updated.durationSeconds = durationSeconds
    onUpdate?(updated)
  }

  private static func formatAlarmTime(hour: Int, minute: Int) -> String {
    var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
    comps.hour = hour
    comps.minute = minute
    if let date = Calendar.current.date(from: comps) {
      return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
    }
    return String(format: "%02d:%02d", hour, minute)
  }
}

// MARK: - Automation Handoff Card (Shortcuts Bridge)

struct AutomationHandoffCardView: View {
  let card: AutomationHandoffCard
  @State private var launchNotice: String?

  private var statusBadge: (text: String, tone: Color) {
    switch card.state {
    case .readyToRun: (String(localized: "Ready"), Theme.Brand.glacier)
    case .completed: (String(localized: "Completed"), Theme.Status.healthy)
    case .failed: (String(localized: "Failed"), Theme.Status.critical)
    case .cancelled: (String(localized: "Cancelled"), Theme.Status.guarded)
    }
  }

  private var retryLabel: String {
    switch card.state {
    case .readyToRun: String(localized: "Run Shortcut")
    case .completed: String(localized: "Run Again")
    case .failed, .cancelled: String(localized: "Retry")
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
              .textSelection(.enabled)
          }
        }
        StatusBadge(text: statusBadge.text, tone: statusBadge.tone)
      }

      if let result = card.resultSummary, !result.isEmpty {
        Text(result)
          .font(.caption)
          .foregroundStyle(Theme.Text.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Theme.Spacing.sm)
          .surfaceCard(radius: Theme.Radius.row)
      }

      if let launchNotice, !launchNotice.isEmpty {
        Label(launchNotice, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(Theme.Status.guarded)
          .accessibilityIdentifier("actionCard.automation.notice")
      }

      WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
        if card.state == .completed {
          ActionCardSecondaryPill(
            title: retryLabel, symbol: "arrow.clockwise", id: "actionCard.automation.retry"
          ) {
            openShortcut(host: "run-shortcut", includeInput: true)
          }
        } else {
          ActionCardPrimaryPill(
            title: retryLabel, symbol: "arrow.clockwise", tint: Theme.Brand.glacier,
            id: "actionCard.automation.retry"
          ) {
            openShortcut(host: "run-shortcut", includeInput: true)
          }
        }
        ActionCardSecondaryPill(
          title: String(localized: "Open in Shortcuts"), symbol: "arrow.up.forward.app",
          id: "actionCard.automation.open"
        ) {
          openShortcut(host: "open-shortcut", includeInput: false)
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.automation")
  }

  private func openShortcut(host: String, includeInput: Bool) {
    launchNotice = nil
    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = host
    var items = [URLQueryItem(name: "name", value: card.shortcutName)]
    if includeInput, let input = card.inputSummary, !input.isEmpty {
      items.append(URLQueryItem(name: "input", value: "text"))
      items.append(URLQueryItem(name: "text", value: input))
    }
    components.queryItems = items
    guard let url = components.url else { return }
    Task {
      let opened = await NativeActions.openExternalURL(url)
      if !opened {
        launchNotice = String(localized: "Couldn't open Apple Shortcuts on this device.")
        Haptics.error()
      }
    }
  }
}
