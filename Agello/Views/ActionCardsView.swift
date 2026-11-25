import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders Swift-verified inline Action Cards produced by tools or structured web lookups.
/// Content-layer surfaces only (no Liquid Glass), mounted strictly after streaming finishes so
/// live replies never shift scroll height.
struct ActionCardStack: View {
  let cards: [ActionCardRecord]
  var isCompact = false

  var body: some View {
    let renderable = cards.filter(\.isRenderable)
    let hasRoute = renderable.contains {
      if case .route = $0.payload { return true }
      return false
    }
    if !renderable.isEmpty {
      if isCompact {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Theme.Spacing.sm) {
            ForEach(renderable) { record in
              cardView(for: record, suppressPlacesSnapshot: hasRoute)
                .frame(width: 280)
            }
          }
          .padding(.horizontal, Theme.Spacing.lg)
        }
      } else {
        // Put RouteCard ahead of PlacesCard when both ran in the same directions turn.
        let ordered = hasRoute
          ? renderable.sorted { lhs, rhs in
            let lIsRoute: Bool = if case .route = lhs.payload { true } else { false }
            let rIsRoute: Bool = if case .route = rhs.payload { true } else { false }
            return lIsRoute && !rIsRoute
          }
          : renderable
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          ForEach(ordered) { record in
            cardView(for: record, suppressPlacesSnapshot: hasRoute)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private func cardView(for record: ActionCardRecord, suppressPlacesSnapshot: Bool) -> some View {
    switch record.payload {
    case .places(let card):
      PlacesCardView(card: card, isCompact: isCompact || suppressPlacesSnapshot)
    case .route(let card):
      RouteCardView(card: card, isCompact: isCompact)
    case .calendarEvent(let card):
      CalendarEventCardView(card: card)
    case .reminder(let card):
      ReminderCardView(card: card)
    case .contact(let card):
      ContactCardView(card: card)
    case .messageDraft(let card):
      MessageDraftCardView(card: card)
    case .weather(let card):
      WeatherCardView(card: card, isCompact: isCompact)
    case .alarm(let card):
      AlarmCardView(card: card)
    case .unknown:
      EmptyView()
    }
  }
}

// MARK: - Places Card (Apple Maps)

private struct PlacesCardView: View {
  let card: PlacesCard
  var isCompact = false
  @Environment(\.displayScale) private var displayScale
  @State private var selectedIndex = 0
  @State private var snapshot: UIImage?
  @State private var detailMapItem: MKMapItem?
  @State private var lookAroundScene: MKLookAroundScene?
  @State private var showsLookAround = false
  @State private var showsFullMap = false
  @State private var showsAllPlaces = false

  private var selectedPlace: PlacesCard.PlaceItem? {
    guard !card.places.isEmpty else { return nil }
    return card.places[min(selectedIndex, card.places.count - 1)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      header
      if !isCompact, let primary = selectedPlace {
        snapshotView(primary: primary)
      }
      if let primary = selectedPlace {
        primaryActions(for: primary)
      }
      if !isCompact, card.places.count > 1 {
        placesList
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.places")
    .task(id: card.places.map(\.id).joined(separator: ",")) {
      guard !isCompact else { return }
      snapshot = await NativeActions.renderMapSnapshot(
        places: card.places, size: CGSize(width: 340, height: 132), scale: displayScale)
    }
    .task(id: selectedPlace?.id) {
      lookAroundScene = nil
      guard !isCompact, let place = selectedPlace else { return }
      lookAroundScene = await NativeActions.checkLookAround(
        latitude: place.latitude, longitude: place.longitude)
    }
    .mapItemDetailSheet(item: $detailMapItem, displaysMap: true)
    .lookAroundViewer(isPresented: $showsLookAround, initialScene: lookAroundScene)
    .sheet(isPresented: $showsFullMap) {
      InteractivePlacesMapSheet(card: card)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
      TintTile(symbol: "mappin.and.ellipse", tint: Theme.Brand.teal)
      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        Text(selectedPlace?.name ?? card.query)
          .font(.system(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.Text.primary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let sub = subtitleLine {
          Text(sub)
            .font(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let meters = selectedPlace?.distanceMeters {
        Text(PersonalToolsLogic.formatDistance(meters))
          .font(.system(.caption, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.Brand.teal)
          .padding(.horizontal, Theme.Spacing.sm)
          .padding(.vertical, Theme.Spacing.xs)
          .background { Capsule().fill(Theme.Brand.teal.opacity(0.14)) }
      }
    }
  }

  private var subtitleLine: String? {
    guard let place = selectedPlace else { return card.areaLabel }
    let parts = [place.category?.capitalized, place.address].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? card.areaLabel : parts.joined(separator: " · ")
  }

  private func snapshotView(primary: PlacesCard.PlaceItem) -> some View {
    Button {
      Haptics.selection()
      showsFullMap = true
    } label: {
      Color.clear
        .frame(height: 124)
        .overlay {
          if let snapshot {
            Image(uiImage: snapshot)
              .resizable()
              .scaledToFill()
          } else {
            ZStack {
              Theme.Surface.card
              HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: "map").foregroundStyle(Theme.Brand.teal)
                Text(primary.address ?? primary.name)
                  .font(.caption)
                  .foregroundStyle(Theme.Text.tertiary)
                  .lineLimit(1)
              }
            }
          }
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Map preview for \(primary.name)")
    .accessibilityHint("Opens an interactive map")
    .accessibilityIdentifier("actionCard.places.mapPreview")
  }

  private func primaryActions(for place: PlacesCard.PlaceItem) -> some View {
    WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
      ActionCardPrimaryPill(
        title: String(localized: "Open in Maps"), symbol: "map.fill", tint: Theme.Brand.teal,
        id: "actionCard.places.openInMaps"
      ) {
        NativeActions.openInMaps(place: place)
      }
      ActionCardSecondaryPill(
        title: String(localized: "Directions"), symbol: "arrow.triangle.turn.up.right.diamond.fill",
        id: "actionCard.places.directions"
      ) {
        NativeActions.openInMaps(place: place, directionsMode: "driving")
      }
      ActionCardSecondaryPill(
        title: String(localized: "Details"), symbol: "info.circle", id: "actionCard.places.details"
      ) {
        Task { detailMapItem = await NativeActions.resolveMapItem(for: place) }
      }
      if lookAroundScene != nil {
        ActionCardSecondaryPill(
          title: String(localized: "Look Around"), symbol: "binoculars.fill",
          id: "actionCard.places.lookAround"
        ) {
          showsLookAround = true
        }
      }
      if let phone = place.phone, let url = NativeActionURLs.phone(phone) {
        ActionCardSecondaryPill(
          title: String(localized: "Call"), symbol: "phone.fill", id: "actionCard.places.call"
        ) {
          NativeActions.openURL(url)
        }
      }
      if let site = NativeActionURLs.website(place.websiteURL) {
        ActionCardSecondaryPill(
          title: String(localized: "Website"), symbol: "safari", id: "actionCard.places.website"
        ) {
          NativeActions.openURL(site)
        }
      }
    }
  }

  private var placesList: some View {
    let visible = showsAllPlaces ? card.places : Array(card.places.prefix(3))
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visible.enumerated()), id: \.element.id) { idx, place in
        Button {
          Haptics.selection()
          selectedIndex = idx
        } label: {
          HStack(spacing: Theme.Spacing.sm) {
            Text("\(idx + 1)")
              .font(.system(.caption2, weight: .bold))
              .monospacedDigit()
              .foregroundStyle(idx == selectedIndex ? Theme.Brand.teal : Theme.Text.tertiary)
              .frame(width: 20, height: 20)
              .background {
                Circle().fill(
                  idx == selectedIndex ? Theme.Brand.teal.opacity(0.18) : Theme.Surface.group)
              }
            VStack(alignment: .leading, spacing: 1) {
              Text(place.name)
                .font(.system(.footnote, weight: idx == selectedIndex ? .semibold : .medium))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
              if let addr = place.address, !addr.isEmpty {
                Text(addr)
                  .font(.caption2)
                  .foregroundStyle(Theme.Text.tertiary)
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let meters = place.distanceMeters {
              Text(PersonalToolsLogic.formatDistance(meters))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.secondary)
            }
          }
          .padding(.vertical, Theme.Spacing.sm)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.Size.target)
        if idx + 1 < visible.count {
          Rectangle().fill(Theme.Surface.hairline).frame(height: Theme.Stroke.hairline)
        }
      }
      if card.places.count > 3 {
        Button {
          withAppAnimation(Theme.Motion.easeOut) { showsAllPlaces.toggle() }
        } label: {
          Text(showsAllPlaces ? "Show fewer" : "Show all \(card.places.count) places")
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.Brand.teal)
            .frame(minHeight: Theme.Size.target, alignment: .leading)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.top, Theme.Spacing.xs)
  }
}

// MARK: - Route / Turn-by-Turn Card

private struct RouteCardView: View {
  let card: RouteCard
  var isCompact = false
  @State private var selectedMode: String
  @State private var showsSteps = false

  init(card: RouteCard, isCompact: Bool = false) {
    self.card = card
    self.isCompact = isCompact
    _selectedMode = State(initialValue: card.transport)
  }

  private var modeSymbol: String {
    switch selectedMode {
    case "walking": "figure.walk"
    case "cycling": "bicycle"
    case "transit": "tram.fill"
    default: "car.fill"
    }
  }

  var body: some View {
    let mins = max(1, Int((card.expectedTravelSeconds / 60.0).rounded()))
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        TintTile(symbol: modeSymbol, tint: Theme.Brand.glacier)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.destinationName)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          let subtitle = [
            card.routeName.map { "via \($0)" },
            card.destinationAddress,
          ].compactMap { $0 }.joined(separator: " · ")
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(Theme.Text.secondary)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(mins) min")
            .font(.system(.subheadline, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.Brand.glacier)
          Text(PersonalToolsLogic.formatDistance(card.distanceMeters))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(Theme.Text.tertiary)
        }
      }

      if !isCompact {
        modePicker
        if !card.steps.isEmpty {
          stepsDisclosure
        } else if selectedMode == "transit" {
          Text("Live transit lines and departures open in Apple Maps.")
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary)
        }
      }

      ActionCardPrimaryPill(
        title: String(localized: "Start in Apple Maps"),
        symbol: "arrow.triangle.turn.up.right.diamond.fill",
        tint: Theme.Brand.glacier,
        fullWidth: true,
        id: "actionCard.route.startInMaps"
      ) {
        NativeActions.openRouteInMaps(card, transportOverride: selectedMode)
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.route")
  }

  private var modePicker: some View {
    let modes: [(id: String, label: String, symbol: String)] = [
      ("driving", "Drive", "car.fill"),
      ("walking", "Walk", "figure.walk"),
      ("cycling", "Cycle", "bicycle"),
      ("transit", "Transit", "tram.fill"),
    ]
    return WrapFlowLayout(horizontalSpacing: Theme.Spacing.tight, verticalSpacing: Theme.Spacing.xs) {
      ForEach(modes, id: \.id) { mode in
        let active = selectedMode == mode.id
        Button {
          Haptics.selection()
          selectedMode = mode.id
        } label: {
          Label(mode.label, systemImage: mode.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: 32)
            .background {
              if active {
                Capsule().fill(Theme.Brand.glacier.opacity(0.24))
                  .overlay { Capsule().stroke(Theme.Brand.glacier.opacity(0.45), lineWidth: 0.8) }
              } else {
                QuietBackground(shape: Capsule())
              }
            }
            .frame(minHeight: Theme.Size.target)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var stepsDisclosure: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      Button {
        withAppAnimation(Theme.Motion.easeOut) { showsSteps.toggle() }
        Haptics.selection()
      } label: {
        HStack(spacing: Theme.Spacing.tight) {
          Text("\(card.steps.count) turn-by-turn steps")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Text.secondary)
          Spacer()
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.Text.tertiary)
            .rotationEffect(.degrees(showsSteps ? 180 : 0))
        }
        .frame(minHeight: Theme.Size.target)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("actionCard.route.stepsToggle")

      if showsSteps {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          ForEach(card.steps) { step in
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
              Text("\(step.id + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Text.tertiary)
                .frame(minWidth: 20, alignment: .trailing)
              Text(step.instruction)
                .font(.caption)
                .foregroundStyle(Theme.Text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
              if step.distanceMeters >= 20 {
                Text(PersonalToolsLogic.formatDistance(step.distanceMeters))
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(Theme.Text.tertiary)
              }
            }
          }
        }
        .padding(Theme.Spacing.sm)
        .surfaceCard(radius: Theme.Radius.row, fill: Theme.Surface.card)
      }
    }
  }
}

// MARK: - Calendar Event Card

private struct CalendarEventCardView: View {
  let card: CalendarEventCard
  @State private var showsEditSheet = false

  private var timeSummary: String {
    if card.isAllDay {
      return card.startDate.formatted(date: .abbreviated, time: .omitted) + " · All day"
    }
    let day = card.startDate.formatted(date: .abbreviated, time: .omitted)
    let start = card.startDate.formatted(date: .omitted, time: .shortened)
    let end = card.endDate.formatted(date: .omitted, time: .shortened)
    return "\(day) · \(start) – \(end)"
  }

  private var statusBadge: (text: String, tone: Color) {
    switch card.status {
    case .created: (String(localized: "Saved"), Theme.Status.healthy)
    case .updated: (String(localized: "Updated"), Theme.Brand.glacier)
    case .deleted: (String(localized: "Deleted"), Theme.Status.critical)
    case .found: (String(localized: "Calendar"), Theme.Brand.lavender)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        TintTile(symbol: "calendar", tint: Theme.Brand.lavender)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(card.status == .deleted ? Theme.Text.tertiary : Theme.Text.primary)
            .strikethrough(card.status == .deleted)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(timeSummary)
            .font(.caption)
            .foregroundStyle(Theme.Text.secondary)
          if let location = card.location, !location.isEmpty {
            Label(location, systemImage: "mappin")
              .font(.caption)
              .foregroundStyle(Theme.Text.tertiary)
              .lineLimit(1)
          }
        }
        StatusBadge(text: statusBadge.text, tone: statusBadge.tone)
      }

      if card.status != .deleted {
        WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
          ActionCardPrimaryPill(
            title: String(localized: "View / Edit Event"), symbol: "calendar.badge.clock",
            tint: Theme.Brand.lavender, id: "actionCard.calendar.edit"
          ) {
            showsEditSheet = true
          }
          if let location = card.location, !location.isEmpty {
            ActionCardSecondaryPill(
              title: String(localized: "Directions"), symbol: "map",
              id: "actionCard.calendar.directions"
            ) {
              NativeActions.openAddressInMaps(location)
            }
          }
          ShareLink(
            item: ICSFileTransfer(card: card),
            preview: SharePreview(card.title, image: Image(systemName: "calendar"))
          ) {
            ActionCardPillLabel(title: String(localized: "Export .ics"), symbol: "square.and.arrow.up")
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("actionCard.calendar.export")
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.calendar")
    .sheet(isPresented: $showsEditSheet) {
      CalendarEventEditSheet(card: card)
    }
  }
}

// MARK: - Reminder Card

private struct ReminderCardView: View {
  let card: ReminderCard
  @State private var isCompleted: Bool
  @State private var dueDate: Date?
  @State private var isUpdating = false

  init(card: ReminderCard) {
    self.card = card
    _isCompleted = State(initialValue: card.isCompleted)
    _dueDate = State(initialValue: card.dueDate)
  }

  private var statusBadge: (text: String, tone: Color)? {
    switch card.status {
    case .created: (String(localized: "Saved"), Theme.Status.healthy)
    case .updated: (String(localized: "Updated"), Theme.Brand.glacier)
    case .completed: (String(localized: "Done"), Theme.Status.healthy)
    case .deleted: (String(localized: "Deleted"), Theme.Status.critical)
    case .found: nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      HStack(spacing: Theme.Spacing.sm) {
        Button {
          toggleCompletion()
        } label: {
          Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isCompleted ? Theme.Status.healthy : Theme.Brand.gold)
            .frame(width: Theme.Size.target, height: Theme.Size.target)
        }
        .buttonStyle(.plain)
        .disabled(isUpdating || card.reminderIdentifier == nil || card.status == .deleted)
        .accessibilityLabel(isCompleted ? "Mark reminder incomplete" : "Mark reminder done")
        .accessibilityIdentifier("actionCard.reminder.toggle")

        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(isCompleted || card.status == .deleted ? Theme.Text.tertiary : Theme.Text.primary)
            .strikethrough(isCompleted || card.status == .deleted)
            .frame(maxWidth: .infinity, alignment: .leading)
          let meta = [
            dueDate.map { $0.formatted(date: .abbreviated, time: .shortened) },
            card.listName,
          ].compactMap { $0 }.joined(separator: " · ")
          if !meta.isEmpty {
            Text(meta)
              .font(.caption)
              .foregroundStyle(Theme.Text.secondary)
          }
        }
        if let badge = statusBadge {
          StatusBadge(text: badge.text, tone: badge.tone)
        }
      }

      if !isCompleted, card.status != .deleted, card.reminderIdentifier != nil {
        WrapFlowLayout(horizontalSpacing: Theme.Spacing.tight, verticalSpacing: Theme.Spacing.xs) {
          ActionCardSecondaryPill(
            title: String(localized: "Snooze +1h"), symbol: "clock.arrow.circlepath",
            id: "actionCard.reminder.snooze1h"
          ) {
            snooze(byHours: 1)
          }
          ActionCardSecondaryPill(
            title: String(localized: "Tomorrow 9 AM"), symbol: "sunrise",
            id: "actionCard.reminder.snoozeTomorrow"
          ) {
            snoozeToTomorrowMorning()
          }
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.reminder")
  }

  private func toggleCompletion() {
    guard let id = card.reminderIdentifier else { return }
    let target = !isCompleted
    isUpdating = true
    Task {
      let result = await PersonalTools.activeBackend.setReminderCompleted(
        identifier: id, completed: target)
      isUpdating = false
      if case .success(let updated) = result {
        isCompleted = updated.isCompleted
        Haptics.complete()
      }
    }
  }

  private func snooze(byHours hours: Int) {
    guard let id = card.reminderIdentifier else { return }
    let base = max(Date.now, dueDate ?? .now)
    let next = base.addingTimeInterval(TimeInterval(hours * 3_600))
    updateDueDate(id: id, to: next)
  }

  private func snoozeToTomorrowMorning() {
    guard let id = card.reminderIdentifier else { return }
    let cal = Calendar.current
    guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)),
      let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    else { return }
    updateDueDate(id: id, to: morning)
  }

  private func updateDueDate(id: String, to targetDate: Date) {
    isUpdating = true
    Task {
      let result = await PersonalTools.activeBackend.updateReminder(
        identifier: id, mutation: ReminderMutation(dueDate: targetDate))
      isUpdating = false
      if case .success(let updated) = result {
        dueDate = updated.dueDate ?? targetDate
        Haptics.complete()
      }
    }
  }
}

// MARK: - Contact Card

private struct ContactCardView: View {
  let card: ContactCard
  @State private var showsContactSheet = false

  private var initials: String {
    let parts = card.fullName.split(separator: " ").prefix(2)
    let letters = parts.compactMap(\.first).map(String.init).joined()
    return letters.isEmpty ? "?" : letters.uppercased()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        Text(initials)
          .font(.system(.subheadline, weight: .bold))
          .foregroundStyle(Theme.Brand.glacier)
          .frame(width: Theme.Size.tile, height: Theme.Size.tile)
          .background { Circle().fill(Theme.Brand.glacier.opacity(0.16)) }
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.fullName)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
          if let org = card.organization, !org.isEmpty {
            Text(org)
              .font(.caption)
              .foregroundStyle(Theme.Text.secondary)
          }
          if let detail = card.phones.first ?? card.emails.first {
            Text(detail)
              .font(.caption)
              .foregroundStyle(Theme.Text.tertiary)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      WrapFlowLayout(horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
        if let phone = card.phones.first, let url = NativeActionURLs.phone(phone) {
          ActionCardPrimaryPill(
            title: String(localized: "Call"), symbol: "phone.fill", tint: Theme.Brand.glacier,
            id: "actionCard.contact.call"
          ) { NativeActions.openURL(url) }
        }
        if let phone = card.phones.first, let url = NativeActionURLs.sms(recipient: phone) {
          ActionCardSecondaryPill(
            title: String(localized: "Message"), symbol: "message.fill",
            id: "actionCard.contact.message"
          ) { NativeActions.openURL(url) }
        }
        if let email = card.emails.first, let url = NativeActionURLs.mailto(recipients: [email]) {
          ActionCardSecondaryPill(
            title: String(localized: "Email"), symbol: "envelope.fill",
            id: "actionCard.contact.email"
          ) { NativeActions.openURL(url) }
        }
        if let target = card.phones.first ?? card.emails.first,
          let url = NativeActionURLs.facetime(target)
        {
          ActionCardSecondaryPill(
            title: String(localized: "FaceTime"), symbol: "video.fill",
            id: "actionCard.contact.facetime"
          ) { NativeActions.openURL(url) }
        }
        if let address = card.postalAddress, !address.isEmpty {
          ActionCardSecondaryPill(
            title: String(localized: "Directions"), symbol: "map",
            id: "actionCard.contact.directions"
          ) { NativeActions.openAddressInMaps(address) }
        }
        ActionCardSecondaryPill(
          title: String(localized: "View"), symbol: "person.crop.circle",
          id: "actionCard.contact.view"
        ) { showsContactSheet = true }
        ShareLink(
          item: VCardFileTransfer(card: card),
          preview: SharePreview(card.fullName, image: Image(systemName: "person.crop.circle"))
        ) {
          ActionCardPillLabel(title: String(localized: "Share"), symbol: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("actionCard.contact.share")
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.contact")
    .sheet(isPresented: $showsContactSheet) {
      ContactDetailSheet(card: card)
    }
  }
}

// MARK: - Message / Mail Draft Card

private struct MessageDraftCardView: View {
  let card: MessageDraftCard
  @State private var showsSMSComposer = false
  @State private var showsMailComposer = false
  @State private var copied = false

  private var canCompose: Bool {
    card.channel == .sms ? NativeActions.canSendText : NativeActions.canSendMail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        TintTile(
          symbol: card.channel == .sms ? "message.fill" : "envelope.fill",
          tint: Theme.Brand.gold)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(card.channel == .sms ? "SMS Draft" : "Email Draft")
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
          Text("To: \(card.recipients.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !card.unverifiedRecipients.isEmpty {
        HStack(alignment: .top, spacing: Theme.Spacing.tight) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.Status.guarded)
          Text("Unverified recipient (not in Contacts): \(card.unverifiedRecipients.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(Theme.Status.guarded)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.sm)
        .surfaceCard(
          radius: Theme.Radius.row, fill: Theme.Status.guarded.opacity(0.12),
          stroke: Theme.Status.guarded.opacity(0.35))
        .accessibilityIdentifier("actionCard.draft.unverifiedWarning")
      }

      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        if let subject = card.subject, !subject.isEmpty {
          Text(subject)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.Text.primary)
        }
        Text(card.body)
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(Theme.Spacing.sm)
      .surfaceCard(radius: Theme.Radius.row, fill: Theme.Surface.card)

      HStack(spacing: Theme.Spacing.sm) {
        if canCompose {
          ActionCardPrimaryPill(
            title: String(localized: "Open Composer"),
            symbol: card.channel == .sms ? "message.fill" : "envelope.fill",
            tint: Theme.Brand.gold,
            id: "actionCard.draft.openComposer"
          ) {
            if card.channel == .sms { showsSMSComposer = true } else { showsMailComposer = true }
          }
        } else {
          ActionCardPrimaryPill(
            title: copied ? String(localized: "Copied Draft") : String(localized: "Copy Draft"),
            symbol: copied ? "checkmark" : "doc.on.doc",
            tint: Theme.Brand.gold,
            id: "actionCard.draft.copyFallback"
          ) {
            Platform.copy(card.body)
            Haptics.complete()
            copied = true
          }
        }
        ShareLink(item: card.body) {
          ActionCardPillLabel(title: String(localized: "Share"), symbol: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("actionCard.draft")
    .sheet(isPresented: $showsSMSComposer) {
      MessageComposeSheet(recipients: card.recipients, body: card.body)
    }
    .sheet(isPresented: $showsMailComposer) {
      MailComposeSheet(recipients: card.recipients, subject: card.subject, body: card.body)
    }
  }
}

// MARK: - Shared Card Controls & Portable File Transfers

private struct ActionCardPrimaryPill: View {
  let title: String
  let symbol: String
  let tint: Color
  var fullWidth = false
  let id: String
  let action: () -> Void

  var body: some View {
    Button {
      Haptics.selection()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .font(.system(.footnote, weight: .semibold))
        .foregroundStyle(Theme.Text.primary)
        .lineLimit(1)
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
        .background { LitTintBackground(shape: Capsule(), tint: tint, strength: .pill) }
        .frame(minHeight: Theme.Size.target)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }
}

private struct ActionCardSecondaryPill: View {
  let title: String
  let symbol: String
  let id: String
  let action: () -> Void

  var body: some View {
    Button {
      Haptics.selection()
      action()
    } label: {
      ActionCardPillLabel(title: title, symbol: symbol)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }
}

private struct ActionCardPillLabel: View {
  let title: String
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.system(.footnote, weight: .medium))
      .foregroundStyle(Theme.Text.secondary)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Spacing.md)
      .frame(minHeight: 36)
      .background { QuietBackground(shape: Capsule()) }
      .frame(minHeight: Theme.Size.target)
      .contentShape(.rect)
  }
}

private struct ICSFileTransfer: Transferable {
  let card: CalendarEventCard

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .calendarEvent) { item in
      Data(NativeActionURLs.icsString(for: item.card).utf8)
    }
    .suggestedFileName { item in
      let slug = item.card.title.replacingOccurrences(of: "/", with: "-")
      return "\(slug.isEmpty ? "event" : slug).ics"
    }
  }
}

private struct VCardFileTransfer: Transferable {
  let card: ContactCard

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .vCard) { item in
      Data(NativeActionURLs.vCardString(for: item.card).utf8)
    }
    .suggestedFileName { item in
      let slug = item.card.fullName.replacingOccurrences(of: "/", with: "-")
      return "\(slug.isEmpty ? "contact" : slug).vcf"
    }
  }
}
