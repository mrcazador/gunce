#if DEBUG
import SwiftUI
import UIKit
import WidgetKit

/// Debug-only: the Home Screen widgets rendered at iPhone sizes from the demo data, so the
/// screenshot tests can check them. Launched with `-demo -demo-widgets` (`-demo-widgets-idle`
/// for the states without an active task).
struct WidgetGallery: View {
    @Environment(AppStore.self) private var store
    let idle: Bool

    private struct Item: Identifiable {
        let id: String
        let family: WidgetFamily
        let snapshot: LockScreenSnapshot
        let height: CGFloat
    }

    private var items: [Item] {
        let active = store.lockScreenSnapshot()
        if idle {
            let parkedOnly = LockScreenSnapshot(
                taskID: nil, state: nil, parkedCount: active.parkedCount, parked: active.parked
            )
            return [
                Item(id: "Orta · park", family: .systemMedium, snapshot: parkedOnly, height: 170),
                Item(id: "Büyük · park", family: .systemLarge, snapshot: parkedOnly, height: 382),
                Item(id: "Orta · boş", family: .systemMedium, snapshot: .empty, height: 170),
            ]
        }
        return [
            Item(id: "Orta · aktif", family: .systemMedium, snapshot: active, height: 170),
            Item(id: "Büyük · aktif", family: .systemLarge, snapshot: .preview, height: 382),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    Text(item.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ActiveTaskWidgetView(family: item.family, snapshot: item.snapshot)
                        .padding(16)
                        .frame(width: 364, height: item.height, alignment: .topLeading)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
#endif
