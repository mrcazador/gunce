import AppIntents
import SwiftUI
import WidgetKit

/// Every widget family. The family is a parameter (not read from the environment) so the
/// app's debug gallery can render the same views for screenshot tests.
struct ActiveTaskWidgetView: View {
    let family: WidgetFamily
    let snapshot: LockScreenSnapshot
    var now: Date = .now

    var body: some View {
        content
            // Widgets have a fixed size: past this, text would be cut instead of growing.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(snapshot: snapshot, now: now)
        case .systemLarge:
            LargeWidgetView(snapshot: snapshot, now: now)
        default:
            if let state = snapshot.state {
                active(state)
            } else {
                idle
            }
        }
    }

    @ViewBuilder
    private func active(_ state: ActiveTaskAttributes.ContentState) -> some View {
        let symbol = state.areaSymbol ?? "bookmark"
        switch family {
        case .accessoryInline:
            Label(state.title, systemImage: symbol)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.caption)
                    Text(StartTime.clock(state.startedAt))
                        .font(.caption2.monospacedDigit())
                        .minimumScaleFactor(0.6)
                }
                .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Şimdi: \(state.title). \(StartTime.spoken(state.startedAt, now: now))")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(StartTime.since(state.startedAt, now: now))
                        .lineLimit(1)
                        .accessibilityLabel(StartTime.spoken(state.startedAt, now: now))
                }
                .font(.caption)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                if let next = state.nextStep {
                    Text("Sıradaki: \(next)")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label(state.areaName ?? "Şimdi", systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AreaPalette.color(state.areaColor))
                    .widgetAccentable()
                    .lineLimit(1)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if let next = state.nextStep {
                    Text(next)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(StartTime.since(state.startedAt, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(StartTime.spoken(state.startedAt, now: now))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var idle: some View {
        let parked = snapshot.parkedCount > 0 ? "\(snapshot.parkedCount) park edilmiş" : "Aklına geleni yaz"
        switch family {
        case .accessoryInline:
            Label("Aktif görev yok", systemImage: "bookmark")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bookmark")
                    .font(.title3)
            }
            .accessibilityLabel("Aktif görev yok")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("PickUp", systemImage: "bookmark")
                    .font(.caption)
                Text("Aktif görev yok")
                    .font(.headline)
                Text(parked)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.title3)
                Spacer(minLength: 0)
                Text("Aktif görev yok")
                    .font(.headline)
                Text(parked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Medium and large

/// Area name with its SF Symbol; the color always comes with the symbol.
private struct AreaTag: View {
    let name: String?
    let symbol: String?
    let color: String?

    var body: some View {
        Label(name ?? "Şimdi", systemImage: symbol ?? "bookmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AreaPalette.color(color))
            .widgetAccentable()
            .lineLimit(1)
    }
}

/// Park notes keep their signature style (New York italic) on the widgets too.
private struct ParkNoteLine: View {
    let note: String
    var lines = 1

    var body: some View {
        Text(note)
            .font(.system(.caption, design: .serif).italic())
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .accessibilityLabel("Kaldığın yer: \(note)")
    }
}

/// A button label sized for a widget column: at least 44 pt tall.
private struct WidgetButtonLabel: View {
    let title: String
    let symbol: String
    let prominent: Bool

    var body: some View {
        let label = Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
        if prominent {
            // The accent is near-black in light and near-white in dark: the label takes the background.
            label
                .foregroundStyle(.background)
                .background(Color.primary, in: Capsule())
        } else {
            label
                .foregroundStyle(.primary)
                .background(Color.primary.opacity(0.12), in: Capsule())
        }
    }
}

/// Title, next step, park note and start time of the active task.
private struct ActiveSummary: View {
    let state: ActiveTaskAttributes.ContentState
    let parkNote: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            AreaTag(name: state.areaName, symbol: state.areaSymbol, color: state.areaColor)
            Text(state.title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let next = state.nextStep {
                Text("Sıradaki: \(next)")
                    .font(.caption)
                    .lineLimit(1)
            }
            if let parkNote {
                ParkNoteLine(note: parkNote)
            }
            Spacer(minLength: 0)
            Text(StartTime.since(state.startedAt, now: now))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(StartTime.spoken(state.startedAt, now: now))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Adımı bitir" (the first open step) and "Bitti". The first one shown is the prominent one.
private struct ActiveButtons: View {
    let taskID: String
    let firstStep: LockScreenSnapshot.Step?

    var body: some View {
        VStack(spacing: 8) {
            if let firstStep {
                Button(intent: CompleteStepIntent(taskID: taskID, stepID: firstStep.id)) {
                    WidgetButtonLabel(title: "Adımı bitir", symbol: "checkmark.circle", prominent: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adımı bitir: \(firstStep.title)")
            }
            Button(intent: CompleteTaskIntent(taskID: taskID)) {
                WidgetButtonLabel(title: "Bitti", symbol: "checkmark", prominent: firstStep == nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Görevi bitir")
        }
        .frame(width: 112)
    }
}

/// A parked task; tapping it opens the app to resume it ("nerede kaldın?" flow).
private struct ParkedLink: View {
    let item: LockScreenSnapshot.Parked

    var body: some View {
        Link(destination: PickUpLink.resume(item.id)) {
            HStack(spacing: 8) {
                Image(systemName: item.areaSymbol ?? "bookmark")
                    .font(.subheadline)
                    .foregroundStyle(AreaPalette.color(item.areaColor))
                    .widgetAccentable()
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let note = item.parkNote, !note.isEmpty {
                        ParkNoteLine(note: note)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: ParkReasonStyle.symbol(item.parkReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(ParkReasonStyle.title(item.parkReason))
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Devam ettirmek için açar")
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// No active task: the most recently parked one with "Devam et", or a capture prompt.
private struct IdleHero: View {
    let snapshot: LockScreenSnapshot
    var noteLines = 2

    var body: some View {
        if let first = snapshot.parked.first {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionTitle(text: "Kaldığın yer")
                    Label(first.title, systemImage: first.areaSymbol ?? "bookmark")
                        .font(.headline)
                        .lineLimit(2)
                        .labelStyle(AreaTintedLabelStyle(color: first.areaColor))
                    if let note = first.parkNote, !note.isEmpty {
                        ParkNoteLine(note: note, lines: noteLines)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Link(destination: PickUpLink.resume(first.id)) {
                    WidgetButtonLabel(title: "Devam et", symbol: "play.fill", prominent: true)
                }
                .frame(width: 112)
            }
        } else {
            Link(destination: PickUpLink.capture) {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .widgetAccentable()
                    Text("Aklına geleni yaz")
                        .font(.headline)
                    Text("Aktif ya da park edilmiş görev yok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Only the icon takes the area color; the title stays primary.
private struct AreaTintedLabelStyle: LabelStyle {
    let color: String?

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .foregroundStyle(AreaPalette.color(color))
                .widgetAccentable()
            configuration.title
        }
    }
}

struct MediumWidgetView: View {
    let snapshot: LockScreenSnapshot
    let now: Date

    var body: some View {
        if let state = snapshot.state, let id = snapshot.taskID {
            HStack(alignment: .top, spacing: 12) {
                ActiveSummary(state: state, parkNote: snapshot.parkNote, now: now)
                ActiveButtons(taskID: id, firstStep: snapshot.upcomingSteps.first)
            }
        } else {
            IdleHero(snapshot: snapshot)
        }
    }
}

struct LargeWidgetView: View {
    let snapshot: LockScreenSnapshot
    let now: Date

    private var steps: [LockScreenSnapshot.Step] { Array(snapshot.upcomingSteps.prefix(3)) }

    /// Rows that fit under the active task: steps first, parked tasks fill the rest.
    private static let rowBudget = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state = snapshot.state, let id = snapshot.taskID {
                HStack(alignment: .top, spacing: 12) {
                    ActiveSummary(state: state, parkNote: snapshot.parkNote, now: now)
                    ActiveButtons(taskID: id, firstStep: snapshot.upcomingSteps.first)
                }
                .frame(height: 120)

                if !steps.isEmpty {
                    Divider()
                    SectionTitle(text: "Sıradaki adımlar")
                    ForEach(steps) { step in
                        Button(intent: CompleteStepIntent(taskID: id, stepID: step.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                Text(step.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.subheadline)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(step.title), tamamla")
                    }
                }
                parkedSection(Array(snapshot.parked.prefix(max(0, Self.rowBudget - steps.count))))
            } else {
                IdleHero(snapshot: snapshot, noteLines: 3)
                    .frame(height: snapshot.parked.isEmpty ? nil : 120)
                parkedSection(Array(snapshot.parked.dropFirst()))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func parkedSection(_ items: [LockScreenSnapshot.Parked]) -> some View {
        if !items.isEmpty {
            Divider()
            SectionTitle(text: "Park'ta bekleyenler")
            ForEach(items.prefix(3)) { item in
                ParkedLink(item: item)
            }
        }
    }
}

// MARK: - Invented data for previews

extension LockScreenSnapshot {
    static let preview = LockScreenSnapshot(
        taskID: "preview",
        state: .init(
            title: "Sunum taslağını bitir",
            areaName: "İş",
            areaSymbol: "briefcase",
            areaColor: "indigo",
            startedAt: .now.addingTimeInterval(-25 * 60),
            nextStep: "Grafikleri güncelle",
            stepsDone: 1,
            stepsTotal: 4
        ),
        parkedCount: 2,
        upcomingSteps: [
            .init(id: "p-s1", title: "Grafikleri güncelle"),
            .init(id: "p-s2", title: "Konuşma notlarını yaz"),
            .init(id: "p-s3", title: "Ekibe gönder"),
        ],
        parkNote: "Gelir tablosunda kaldım, giderler eksik.",
        parked: previewParked
    )

    static let previewIdle = LockScreenSnapshot(taskID: nil, state: nil, parkedCount: 3, parked: previewParked)

    private static let previewParked: [Parked] = [
        .init(id: "p-t1", title: "Kira sözleşmesini yenile", areaSymbol: "heart", areaColor: "pink",
              parkNote: "Ev sahibinden yeni fiyatı bekliyorum.", parkReason: "waiting"),
        .init(id: "p-t2", title: "Fon dağılımını gözden geçir", areaSymbol: "chart.line.uptrend.xyaxis",
              areaColor: "green", parkNote: "Tahvil oranı eksik.", parkReason: "need_info"),
        .init(id: "p-t3", title: "Koşu planını ayarla", areaSymbol: "figure.run", areaColor: "orange",
              parkNote: nil, parkReason: "later"),
    ]
}
