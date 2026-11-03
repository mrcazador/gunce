import SwiftUI

/// "Şehir": the city built from your work. Every task is a building; checked-off steps raise
/// its floors, sites without progress stand still and slowly fade, and work finished after a
/// long wait becomes a landmark. The city grows a level at a time (Bina, Site, Mahalle, Şehir)
/// and each level changes how the streets look. Nothing to manage: look at it now and then.
struct CityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: CityBuilding?
    /// Map scale; nil fits the whole city on screen.
    @State private var zoom: CGFloat?
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    /// The building the map is zoomed in on while its card is open. The map's own pan and
    /// zoom stay as they were, so closing the card returns to them.
    @State private var focusID: String?
    /// Full screen height, to know where the card's top edge is.
    @State private var screenHeight: CGFloat = 0
    /// Bumped each time the tab opens: trees, lamps and benches pop in again.
    @State private var popBeat = 0
    /// The highest level already celebrated, so a level-up is shown once.
    @AppStorage("pickup.city.seenLevel") private var seenLevel = -1
    @State private var celebrating: CityLevel?
    /// A task opened from a building card, pushed here instead of jumping to Şimdi.
    @State private var openID: String?
    @State private var showStory = false

    static let tile: CGFloat = 78
    static let focusScale: CGFloat = 1.5
    /// The building card covers this share of the screen.
    static let cardShare: CGFloat = 0.42

    var body: some View {
        let city = store.city()
        let layout = CityLayout(city: city, areas: store.sortedAreas, tile: Self.tile)
        NavigationStack {
            VStack(spacing: 0) {
                // While a building is in focus the header steps aside, so the map gets the room.
                if focusID == nil, !city.buildings.isEmpty {
                    CityHeader(city: city) { showStory = true }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if city.buildings.isEmpty {
                    ContentUnavailableView {
                        Label("Şehrin boş", systemImage: "building.2")
                    } description: {
                        Text("İlk görevini yaz; arsası hemen ayrılır.")
                    } actions: {
                        Button("Görev ekle") { store.captureRequest = CaptureRequest() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    GeometryReader { proxy in
                        let focused = focusOffset(layout, map: proxy.frame(in: .global))
                        let scale = focused == nil ? currentScale(layout: layout, in: proxy.size) : Self.focusScale
                        let offset = focused ?? CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
                        CityCanvas(layout: layout, level: city.level, selectedID: selected?.id, popBeat: popBeat) {
                            focus($0)
                        }
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .clipped()
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    pan.width += value.translation.width
                                    pan.height += value.translation.height
                                }
                                .simultaneously(with:
                                    MagnifyGesture()
                                        .updating($pinch) { value, state, _ in state = value.magnification }
                                        .onEnded { value in
                                            zoom = Self.clamp((zoom ?? fit(layout, proxy.size)) * value.magnification)
                                        }
                                )
                        )
                    }
                    .background(CitySky(level: city.level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBackground)
            .background {
                GeometryReader { screen in
                    Color.clear
                        .onAppear { screenHeight = screen.size.height }
                        .onChange(of: screen.size.height) { _, height in screenHeight = height }
                }
                .ignoresSafeArea()
            }
            .navigationTitle("Şehir")
            .navigationBarTitleDisplayMode(focusID == nil ? .large : .inline)
            .sheet(item: $selected, onDismiss: unfocus) { building in
                CityBuildingSheet(building: building) { openID = $0 }
            }
            .sheet(isPresented: $showStory) {
                CityStorySheet(city: city) { focus($0) }
            }
            .navigationDestination(item: $openID) { id in
                TaskDetailView(taskID: id)
            }
            .overlay {
                if let level = celebrating {
                    LevelUpCard(level: level) {
                        seenLevel = level.rawValue
                        withAnimation(reduceMotion ? nil : .snappy) { celebrating = nil }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.success, trigger: celebrating)
            .onAppear {
                if !reduceMotion { popBeat += 1 }
                checkLevel(city)
            }
        }
    }

    // MARK: Map

    private static func clamp(_ value: CGFloat) -> CGFloat { min(2.6, max(0.35, value)) }

    /// The scale that fits the whole city on screen (never larger than 1).
    private func fit(_ layout: CityLayout, _ size: CGSize) -> CGFloat {
        guard layout.size.width > 0, layout.size.height > 0 else { return 1 }
        return min(1, size.width / layout.size.width, size.height / layout.size.height)
    }

    private func currentScale(layout: CityLayout, in size: CGSize) -> CGFloat {
        Self.clamp((zoom ?? fit(layout, size)) * pinch)
    }

    /// Zooms in on a building and opens its card.
    private func focus(_ building: CityBuilding) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) {
            focusID = building.id
        }
        selected = building
    }

    private func unfocus() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
            focusID = nil
        }
    }

    /// Where to move the canvas so the focused building sits in the middle of the map's
    /// visible part: between the map's top and the top of the card. Worked out from the
    /// map's real frame on screen, so it holds whatever the header and bars take.
    private func focusOffset(_ layout: CityLayout, map: CGRect) -> CGSize? {
        guard let focusID, let centre = layout.centre(of: focusID) else { return nil }
        let fromMiddle = CGSize(
            width: (centre.x - layout.size.width / 2) * Self.focusScale,
            height: (centre.y - layout.size.height / 2) * Self.focusScale
        )
        let screen = screenHeight > 0 ? screenHeight : map.maxY
        let cardTop = min(map.maxY, screen * (1 - Self.cardShare))
        let visibleMiddle = (map.minY + cardTop) / 2
        let wanted = visibleMiddle - map.midY
        return CGSize(width: -fromMiddle.width, height: wanted - fromMiddle.height)
    }

    /// Shows the level-up card once when the city has grown since it was last opened.
    private func checkLevel(_ city: CitySummary) {
        let level = city.level.rawValue
        if seenLevel < 0 || level < seenLevel {
            seenLevel = level
        } else if level > seenLevel {
            withAnimation(reduceMotion ? nil : .snappy) { celebrating = city.level }
        }
    }
}

/// Everything about the city that does not need to be on the map: where it stands in its
/// story, what the next level brings, and the sites waiting for a step.
private struct CityStorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let city: CitySummary
    let focus: (CityBuilding) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CityLevel.allCases, id: \.self) { level in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: level.rawValue < city.level.rawValue ? "checkmark.circle.fill"
                                  : level == city.level ? "largecircle.fill.circle" : "circle.dashed")
                                .foregroundStyle(level.rawValue <= city.level.rawValue ? Color.themeBrick : Color.secondary)
                                .font(.title3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level == .building ? level.title : "\(level.title) · \(level.threshold) bina")
                                    .font(.headline)
                                Text(level.rawValue <= city.level.rawValue ? level.story : "Açılacak: \(level.unlock.lowercased(with: Locale(identifier: "tr")))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Şehrin hikâyesi")
                } footer: {
                    if let next = city.level.next {
                        Text("\(next.title) için \(next.threshold - city.finished) iş daha bitir.")
                    }
                }

                Section("Nasıl büyür?") {
                    Label("Her iş bir bina, her tamamlanan adım bir kat.", systemImage: "building.2")
                    Label("3 gün adım atılmazsa vinç durur, 7 günde şantiye terk edilir. Bir adım onu yeniden başlatır.", systemImage: "pause.circle")
                    Label("Büyüklük (Ufak, Orta, Büyük) biten binanın ne kadar gösterişli olacağını seçer.", systemImage: "square.stack.3d.up")
                    Label("Uzun bekleyip sonunda bitirdiğin iş anıt yapı olur.", systemImage: "star")
                    Label("Bittikten iki gün sonra binaya taşınılır, ışıkları yanar.", systemImage: "lightbulb")
                }
                .font(.subheadline)

                if !city.stalled.isEmpty {
                    Section {
                        ForEach(city.stalled) { building in
                            Button {
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    focus(building)
                                }
                            } label: {
                                HStack {
                                    Label(building.title, systemImage: building.stage == .abandoned ? "exclamationmark.triangle" : "pause.circle")
                                    Spacer()
                                    Text("\(building.idleDays) gün")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Duran inşaatlar")
                    } footer: {
                        Text("Bir binaya dokunursan harita ona yaklaşır.")
                    }
                }
            }
            .themedBackground()
            .navigationTitle(city.level.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shown once when the city reaches a new level.
private struct LevelUpCard: View {
    let level: CityLevel
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture(perform: done)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Image(systemName: "building.2.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.themeBrick)
                    .accessibilityHidden(true)
                Text("Şehrin büyüdü: \(level.title)")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(level.story)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Label("Açıldı: \(level.unlock)", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                ActionButton(title: "Şehre bak", symbol: "eye", prominent: true, action: done)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color.themeBackground, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

// MARK: - Building card

/// The card under a focused building: the task's state, where you left off, its steps (check
/// them off right here) and the one action that moves it on. The city stays visible above.
private struct CityBuildingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let building: CityBuilding
    let openTask: (String) -> Void

    var body: some View {
        // Live copy: checking off a step here raises the building at once.
        let live = store.city().buildings.first { $0.id == building.id } ?? building
        let task = store.tasks[building.id]
        let steps = store.subtasks(of: building.id).filter { $0.deletedAt == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let area = store.area(live.areaId) {
                            AreaLabel(area: area)
                                .font(.subheadline)
                        }
                        Text(live.title)
                            .font(.title3.weight(.semibold))
                        Text(CityText.stage(live))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Kapat", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.themeCard, in: Circle())
                        .buttonStyle(.plain)
                }

                if live.stepsTotal > 0 {
                    BrickProgress(done: live.stepsDone, total: live.stepsTotal, label: "\(live.stepsTotal) adımın \(live.stepsDone) tanesi bitti")
                }

                if let note = live.parkNote, !note.isEmpty, live.stage != .finished {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kaldığın yer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParkNoteText(note: note)
                    }
                }

                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Adımlar · \(live.stepsDone)/\(live.stepsTotal) kat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(steps) { step in
                            StepRow(step: step)
                        }
                    }
                }

                if let task, task.status.isOpen {
                    ActionRow {
                        switch task.status {
                        case .active:
                            ActionButton(title: "Ara ver", symbol: "pause.fill", prominent: true) {
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    store.requestPark(task)
                                }
                            }
                        default:
                            ActionButton(title: task.status == .parked ? "Devam et" : "Başla", symbol: "play.fill", prominent: true) {
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    store.requestStart(task)
                                }
                            }
                        }
                        ActionButton(title: "Bitti", symbol: "checkmark") {
                            Task { await store.complete(task) }
                        }
                    }
                }

                Button("Görevi aç", systemImage: "arrow.up.right") {
                    dismiss()
                    openTask(building.id)
                }
                .frame(minHeight: 44)

                if live.stage == .abandoned {
                    Text("Bir adım tamamlarsan inşaat yeniden başlar; bitirirsen şehrin anıt yapılarından biri olur.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .presentationDetents([.fraction(CityView.cardShare), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(CityView.cardShare)))
        .presentationBackground(Color.themeBackground)
        .presentationDragIndicator(.visible)
    }
}

/// One step in the building card: tap to check it off.
private struct StepRow: View {
    @Environment(AppStore.self) private var store
    let step: TaskItem

    var body: some View {
        let done = step.status == .done
        Button {
            if !done { Task { await store.complete(step) } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.themeSage : Color.secondary)
                Text(step.title)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .accessibilityLabel(done ? "\(step.title), tamamlandı" : "\(step.title), tamamla")
    }
}
