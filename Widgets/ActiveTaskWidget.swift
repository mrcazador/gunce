import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: LockScreenSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .preview : SharedSnapshot.load()))
    }

    /// The app reloads the timeline after every task change, so one entry is enough.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: SharedSnapshot.load())], policy: .never))
    }
}

/// Lock Screen and Home Screen widget: the task you are on, and for how long.
struct ActiveTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ActiveTask", provider: SnapshotProvider()) { entry in
            ActiveTaskWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(PickUpLink.now)
        }
        .configurationDisplayName("Şimdi")
        .description("Üzerinde çalıştığın görev ve geçen süre.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall])
    }
}

struct ActiveTaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: LockScreenSnapshot

    var body: some View {
        if let state = snapshot.state {
            active(state)
        } else {
            idle
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
                    Text(state.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
                .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Şimdi: \(state.title)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(state.startedAt, style: .timer)
                        .monospacedDigit()
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
                Text(state.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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

extension LockScreenSnapshot {
    /// Invented example for the widget gallery.
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
            stepsTotal: 3
        ),
        parkedCount: 2
    )
}
