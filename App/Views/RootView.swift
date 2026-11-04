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
    case now, tasks, city, search
}

struct MainTabs: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now
    /// The first-run tour, shown once after the first sign-in.
    @AppStorage("pickup.onboarded") private var onboarded = false
    @State private var showTutorial = false

    var body: some View {
        @Bindable var store = store
        TabView(selection: $selection) {
            Tab("Şimdi", systemImage: "bookmark", value: AppTab.now) {
                NowView()
            }
            Tab("Görevler", systemImage: "checklist", value: AppTab.tasks) {
                TasksView()
            }
            Tab("Şehir", systemImage: "building.2", value: AppTab.city) {
                CityView()
            }
            Tab("Ara", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewBottomAccessory {
            CaptureBar()
        }
        // Soft, rounded type for the game-like look; park notes keep their serif italic.
        .fontDesign(.rounded)
        .overlay(alignment: .bottom) {
            if let undo = store.lastVoice {
                VoiceBanner(undo: undo)
                    .padding(.bottom, 130)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let undo = store.lastCompletion {
                UndoBanner(undo: undo)
                    .padding(.bottom, 130)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.lastCompletion?.id)
        .animation(.snappy, value: store.lastVoice?.id)
        .fullScreenCover(isPresented: $showTutorial, onDismiss: { onboarded = true }) {
            OnboardingView()
        }
        .onAppear {
            // Demo runs (screenshots) skip the tour unless asked for it with `-tutorial`.
            let asked = ProcessInfo.processInfo.arguments.contains("-tutorial")
            if !onboarded && (!store.isDemo || asked) { showTutorial = true }
        }
        .sheet(item: $store.captureRequest) { request in
            CaptureSheet(request: request)
        }
        .sheet(item: $store.voiceRequest) { request in
            VoiceSheet(taskID: request.taskID, noteOnly: request.noteOnly)
        }
        .sheet(item: $store.limitRequest) { request in
            LimitSheet(request: request)
        }
        .sheet(isPresented: $store.reviewRequested) {
            ReviewSheet()
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
        // Sync now and then every minute while the app is open, so tasks Claude adds and
        // changes made offline go through without pulling to refresh.
        .task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await store.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refresh() }
            }
        }
    }
}

/// "Bitti · Geri al" for a few seconds after finishing a task.
private struct UndoBanner: View {
    @Environment(AppStore.self) private var store
    let undo: CompletionUndo

    @State private var picked: TaskSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.themeSage)
                    .accessibilityHidden(true)
                Text("“\(undo.task.title)” bitti")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Geri al") {
                    Task { await store.undoCompletion() }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
            }
            // Size is asked once the work is done, when it is easy to judge; it picks how grand
            // the building is. Skipping keeps it Orta.
            HStack(spacing: 8) {
                Text("Ne kadar büyüktü?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(TaskSize.allCases) { size in
                    Button(size.title) {
                        picked = size
                        if let task = store.tasks[undo.task.id] {
                            Task { await store.edit(task) { $0.priority = size.rawValue } }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(picked == size ? Color.themeBrick : Color.secondary)
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(8))
            if store.lastCompletion?.id == undo.id { store.lastCompletion = nil }
        }
    }
}
