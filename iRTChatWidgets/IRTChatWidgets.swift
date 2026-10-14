import AppIntents
import SwiftUI
import WidgetKit

@main
struct IRTChatWidgets: WidgetBundle {
  var body: some Widget {
    QuickActionsWidget()
    TalkControl()
    NewChatControl()
  }
}

// MARK: - Home Screen and Lock Screen

/// Shortcuts into iRTChat: a new chat, or a voice conversation. The model
/// runs in the app, so widgets only open it.
struct QuickActionsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "QuickActions", provider: QuickActionsProvider()) { _ in
      QuickActionsView()
        .containerBackground(for: .widget) { WidgetPalette.background }
    }
    .configurationDisplayName("iRTChat")
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
  static let newChat = URL(string: "irtchat://new")!
  static let voice = URL(string: "irtchat://voice")!
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
      .accessibilityLabel("Talk to iRTChat")
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 2) {
        Label("iRTChat", systemImage: "sparkles").font(.headline)
        Text("Ask anything").font(.caption)
      }
      .widgetURL(WidgetLinks.newChat)
    case .systemMedium:
      HStack(spacing: 12) {
        action("New chat", symbol: "square.and.pencil", tint: WidgetPalette.glacier, url: WidgetLinks.newChat)
        action("Talk", symbol: "waveform", tint: WidgetPalette.gold, url: WidgetLinks.voice)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "sparkles")
          .font(.title2.weight(.semibold))
          .foregroundStyle(WidgetPalette.glacier)
        Spacer()
        Text("Ask iRTChat")
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
    StaticControlConfiguration(kind: "com.patricedery.irtchat.talk") {
      ControlWidgetButton(action: StartVoiceModeIntent()) {
        Label("Talk to iRTChat", systemImage: "waveform")
      }
    }
    .displayName("Talk to iRTChat")
    .description("Start a hands-free voice conversation.")
  }
}

struct NewChatControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.patricedery.irtchat.newchat") {
      ControlWidgetButton(action: NewChatIntent()) {
        Label("New iRTChat chat", systemImage: "square.and.pencil")
      }
    }
    .displayName("New iRTChat chat")
    .description("Start a new chat.")
  }
}
