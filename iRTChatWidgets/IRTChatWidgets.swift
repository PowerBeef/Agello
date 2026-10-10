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
        .containerBackground(.fill.tertiary, for: .widget)
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
        action("New chat", symbol: "square.and.pencil", url: WidgetLinks.newChat)
        action("Talk", symbol: "waveform", url: WidgetLinks.voice)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "sparkles")
          .font(.title2)
          .foregroundStyle(Color.accentColor)
        Spacer()
        Text("Ask iRTChat")
          .font(.headline)
        Text("Private, on-device")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(WidgetLinks.newChat)
    }
  }

  private func action(_ title: LocalizedStringKey, symbol: String, url: URL) -> some View {
    Link(destination: url) {
      VStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.title2)
        Text(title)
          .font(.subheadline.weight(.medium))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.fill.secondary, in: .rect(cornerRadius: 16))
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
