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

    /// The app reloads the timeline after every task change; otherwise it refreshes at midnight.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // "Dün" and dates change at midnight, so refresh then as well.
        let entry = SnapshotEntry(date: .now, snapshot: SharedSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(StartTime.nextChange())))
    }
}

/// Lock Screen and Home Screen widget: the task you are on, its next steps and what is parked.
struct ActiveTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ActiveTask", provider: SnapshotProvider()) { entry in
            ActiveTaskEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(PickUpLink.now)
        }
        .configurationDisplayName("Şimdi")
        .description("Üzerinde çalıştığın görev.")
        .supportedFamilies([
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
            .systemSmall, .systemMedium, .systemLarge,
        ])
    }
}

private struct ActiveTaskEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        ActiveTaskWidgetView(family: family, snapshot: entry.snapshot, now: entry.date)
    }
}

// MARK: - Previews (invented data)

#Preview("Kilit ekranı", as: .accessoryRectangular) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
}

#Preview("Yuvarlak", as: .accessoryCircular) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
}

#Preview("Satır", as: .accessoryInline) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
}

#Preview("Küçük", as: .systemSmall) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
}

#Preview("Orta", as: .systemMedium) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
    SnapshotEntry(date: .now, snapshot: .empty)
}

#Preview("Büyük", as: .systemLarge) {
    ActiveTaskWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: .previewIdle)
    SnapshotEntry(date: .now, snapshot: .empty)
}
