import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.isSignedIn {
            MainTabs()
        } else {
            SignInView()
        }
    }
}

enum AppTab: Hashable {
    case now, tasks, today, search
}

struct MainTabs: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now

    var body: some View {
        @Bindable var store = store
        TabView(selection: $selection) {
            Tab("Şimdi", systemImage: "bookmark", value: AppTab.now) {
                NowView()
            }
            Tab("Görevler", systemImage: "checklist", value: AppTab.tasks) {
                TasksView()
            }
            Tab("Bugün", systemImage: "calendar", value: AppTab.today) {
                TodayView()
            }
            Tab("Ara", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewBottomAccessory {
            CaptureBar()
        }
        .sheet(item: $store.captureRequest) { request in
            CaptureSheet(request: request)
        }
        .sheet(item: $store.parkRequest) { request in
            ParkSheet(request: request)
        }
        .alert(
            "Olmadı",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        // Haptics for the actions that change what you are working on.
        .sensoryFeedback(.success, trigger: store.completions)
        .sensoryFeedback(.impact(weight: .medium), trigger: store.parks)
        .sensoryFeedback(.impact(weight: .light), trigger: store.starts)
        .sensoryFeedback(.selection, trigger: store.captures)
        .onChange(of: store.openTaskID) { _, id in
            if id != nil { selection = .now }
        }
        // Links from the Lock Screen widget and Live Activity.
        .onOpenURL { url in
            guard url.scheme == "pickup" else { return }
            selection = .now
            switch url.host {
            case "park":
                if let task = store.activeTask, store.parkRequest == nil {
                    store.requestPark(task)
                }
            case "resume":
                // pickup://resume/<id>: the usual start flow, which asks "nerede kaldın?" first.
                if let id = url.pathComponents.dropFirst().first, let task = store.tasks[id],
                   task.status.isOpen, task.parentId == nil, store.parkRequest == nil {
                    store.requestStart(task)
                }
            case "capture":
                if store.captureRequest == nil {
                    store.captureRequest = CaptureRequest()
                }
            default:
                break
            }
        }
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refresh() }
            }
        }
    }
}
