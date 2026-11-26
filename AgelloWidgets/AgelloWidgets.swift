import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgelloWidgets: WidgetBundle {
  var body: some Widget {
    QuickActionsWidget()
    AgelloAlarmLiveActivity()
    TalkControl()
    NewChatControl()
    SnapAndAskControl()
    VoiceWithCameraControl()
  }
}

// MARK: - Home Screen and Lock Screen

/// Shortcuts into Agello: a new chat, or a voice conversation. The model
/// runs in the app, so widgets only open it.
struct QuickActionsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "QuickActions", provider: QuickActionsProvider()) { _ in
      QuickActionsView()
        .containerBackground(for: .widget) { WidgetPalette.background }
    }
    .configurationDisplayName("Agello")
    .description("Start a chat or talk to your on-device assistant.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
  }
}

struct QuickActionsEntry: TimelineEntry {
  let date: Date
}

struct QuickActionsProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: .now) }

  func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
    completion(QuickActionsEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
    completion(Timeline(entries: [QuickActionsEntry(date: .now)], policy: .never))
  }
}

/// The app's palette (see the app's Theme), for the widget extension.
enum WidgetPalette {
  static let canvas = Color(red: 0.086, green: 0.094, blue: 0.137)
  static let canvasBottom = Color(red: 0.038, green: 0.044, blue: 0.056)
  static let glacier = Color(red: 0.541, green: 0.690, blue: 0.784)
  static let teal = Color(red: 0.459, green: 0.761, blue: 0.733)
  static let gold = Color(red: 0.929, green: 0.800, blue: 0.541)
  static let text = Color(red: 0.95, green: 0.94, blue: 0.92)
  static let secondary = Color(red: 0.78, green: 0.76, blue: 0.72)

  static var background: some View {
    ZStack {
      LinearGradient(colors: [canvas, canvasBottom], startPoint: .top, endPoint: .bottom)
      RadialGradient(
        colors: [glacier.opacity(0.32), .clear], center: .top, startRadius: 0, endRadius: 180)
    }
  }
}

enum WidgetLinks {
  static let open = URL(string: "agello://open")!
  static let newChat = URL(string: "agello://new")!
  static let voice = URL(string: "agello://voice")!
  static let snapAndAsk = URL(string: "agello://camera")!
  static let voiceWithCamera = URL(string: "agello://voice-camera")!
}

struct QuickActionsView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "waveform")
          .font(.title3)
      }
      .widgetURL(WidgetLinks.voice)
      .accessibilityLabel("Talk to Agello")
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 2) {
        Label("Agello", systemImage: "sparkles").font(.headline)
        Text("Ask anything").font(.caption)
      }
      .widgetURL(WidgetLinks.newChat)
    case .systemMedium:
      HStack(spacing: 10) {
        action("New chat", symbol: "square.and.pencil", tint: WidgetPalette.glacier, url: WidgetLinks.newChat)
        action("Snap", symbol: "camera.viewfinder", tint: WidgetPalette.teal, url: WidgetLinks.snapAndAsk)
        action("Talk", symbol: "waveform", tint: WidgetPalette.gold, url: WidgetLinks.voice)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "sparkles")
          .font(.title2.weight(.semibold))
          .foregroundStyle(WidgetPalette.glacier)
        Spacer()
        Text("Ask Agello")
          .font(.headline)
          .foregroundStyle(WidgetPalette.text)
        Text("Private, on-device")
          .font(.caption)
          .foregroundStyle(WidgetPalette.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(WidgetLinks.newChat)
    }
  }

  private func action(_ title: LocalizedStringKey, symbol: String, tint: Color, url: URL) -> some View {
    Link(destination: url) {
      VStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.title2.weight(.semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(WidgetPalette.text)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0.12)], startPoint: .top, endPoint: .bottom))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
      }
    }
  }
}

// MARK: - Control Center, Lock Screen controls, Action Button

struct TalkControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.patricedery.agello.talk") {
      ControlWidgetButton(action: StartVoiceModeIntent()) {
        Label("Talk to Agello", systemImage: "waveform")
      }
    }
    .displayName("Talk to Agello")
    .description("Start a hands-free voice conversation.")
  }
}

struct NewChatControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.patricedery.agello.newchat") {
      ControlWidgetButton(action: NewChatIntent()) {
        Label("New Agello chat", systemImage: "square.and.pencil")
      }
    }
    .displayName("New Agello chat")
    .description("Start a new chat.")
  }
}

struct SnapAndAskControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.patricedery.agello.snapandask") {
      ControlWidgetButton(action: SnapAndAskIntent()) {
        Label("Snap & Ask Agello", systemImage: "camera.viewfinder")
      }
    }
    .displayName("Snap & Ask Agello")
    .description("Take a photo and ask Agello about it.")
  }
}

struct VoiceWithCameraControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.patricedery.agello.voicecamera") {
      ControlWidgetButton(action: VoiceWithCameraIntent()) {
        Label("Voice with Camera", systemImage: "video.fill")
      }
    }
    .displayName("Voice with Camera")
    .description("Start a hands-free voice conversation with the camera on.")
  }
}

// MARK: - AlarmKit Live Activity & Dynamic Island

struct AgelloAlarmLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AlarmAttributes<AgelloAlarmMetadata>.self) { context in
      AlarmBannerView(context: context)
        .activityBackgroundTint(WidgetPalette.canvas)
        .activitySystemActionForegroundColor(WidgetPalette.gold)
        .widgetURL(WidgetLinks.open)
    } dynamicIsland: { context in
      let isAlarm = context.attributes.metadata?.kind == "alarm"
      let symbol = isAlarm ? "alarm.fill" : "timer"
      let kindLabel = isAlarm ? String(localized: "Alarm") : String(localized: "Timer")
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(
            context.attributes.metadata?.label ?? "Agello",
            systemImage: symbol
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(WidgetPalette.text)
          .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          AlarmTrailingTimeView(state: context.state, compact: false)
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(WidgetPalette.gold)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 10) {
            AlarmControlsView(state: context.state)
          }
          .padding(.top, 4)
        }
      } compactLeading: {
        Image(systemName: symbol)
          .foregroundStyle(WidgetPalette.gold)
          .accessibilityLabel(kindLabel)
      } compactTrailing: {
        AlarmTrailingTimeView(state: context.state, compact: true)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(WidgetPalette.gold)
      } minimal: {
        Image(systemName: symbol)
          .foregroundStyle(WidgetPalette.gold)
          .accessibilityLabel(kindLabel)
      }
      .widgetURL(WidgetLinks.open)
    }
  }
}

private struct AlarmBannerView: View {
  let context: ActivityViewContext<AlarmAttributes<AgelloAlarmMetadata>>
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  private var isAlarm: Bool {
    context.attributes.metadata?.kind == "alarm"
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: isAlarm ? "alarm.fill" : "timer")
        .font(.title2)
        .foregroundStyle(WidgetPalette.gold.opacity(isLuminanceReduced ? 0.65 : 1))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.metadata?.label ?? "Agello")
          .font(.headline)
          .foregroundStyle(WidgetPalette.text.opacity(isLuminanceReduced ? 0.8 : 1))
          .lineLimit(1)
        AlarmTrailingTimeView(state: context.state, compact: false)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(WidgetPalette.secondary)
      }
      Spacer(minLength: 8)
      if !isLuminanceReduced {
        AlarmControlsView(state: context.state)
      }
    }
    .padding(14)
  }
}

private struct AlarmTrailingTimeView: View {
  let state: AlarmPresentationState
  var compact: Bool = false
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  var body: some View {
    switch state.mode {
    case .countdown(let countdown):
      let now = Date.now
      if isLuminanceReduced {
        Text(countdown.fireDate.formatted(Date.FormatStyle(date: .omitted, time: .shortened)))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxWidth: compact ? 56 : nil, alignment: .trailing)
      } else if countdown.fireDate > now {
        Text(timerInterval: now...max(now, countdown.fireDate), countsDown: true)
          .multilineTextAlignment(.trailing)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxWidth: compact ? 56 : nil, alignment: .trailing)
      } else {
        Text("0:00")
          .lineLimit(1)
          .frame(maxWidth: compact ? 56 : nil, alignment: .trailing)
      }
    case .paused(let paused):
      let remaining = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
      Text(Self.formatPausedDuration(remaining, compact: compact))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: compact ? 56 : nil, alignment: .trailing)
    case .alert(let alert):
      Text(Self.formatAlertTime(hour: alert.time.hour, minute: alert.time.minute))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    @unknown default:
      Text("Active")
        .lineLimit(1)
    }
  }

  private static func formatPausedDuration(_ seconds: TimeInterval, compact: Bool) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    let clock =
      hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
    return compact ? clock : "\(clock) paused"
  }

  private static func formatAlertTime(hour: Int, minute: Int) -> String {
    var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
    comps.hour = hour
    comps.minute = minute
    if let date = Calendar.current.date(from: comps) {
      return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
    }
    return String(format: "%02d:%02d", hour, minute)
  }
}

private struct AlarmControlsView: View {
  let state: AlarmPresentationState

  var body: some View {
    let idString = state.alarmID.uuidString
    switch state.mode {
    case .countdown:
      Button(intent: PauseAgelloAlarmIntent(alarmID: idString)) {
        Image(systemName: "pause.fill")
      }
      .buttonStyle(.bordered)
      .tint(WidgetPalette.glacier)
      .accessibilityLabel(String(localized: "Pause timer"))

      Button(intent: StopAgelloAlarmIntent(alarmID: idString)) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.bordered)
      .tint(WidgetPalette.gold)
      .accessibilityLabel(String(localized: "Cancel timer"))
    case .paused:
      Button(intent: ResumeAgelloAlarmIntent(alarmID: idString)) {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .tint(WidgetPalette.teal)
      .accessibilityLabel(String(localized: "Resume timer"))

      Button(intent: StopAgelloAlarmIntent(alarmID: idString)) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.bordered)
      .tint(WidgetPalette.gold)
      .accessibilityLabel(String(localized: "Cancel timer"))
    case .alert:
      Button(intent: StopAgelloAlarmIntent(alarmID: idString)) {
        Label("Stop", systemImage: "stop.fill")
      }
      .buttonStyle(.borderedProminent)
      .tint(WidgetPalette.gold)
      .accessibilityLabel(String(localized: "Stop alarm"))
    @unknown default:
      EmptyView()
    }
  }
}
