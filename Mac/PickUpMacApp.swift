import AppKit
import SwiftUI
import UserNotifications

@main
struct PickUpMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("PickUp", id: "main") {
            mainContent
                .environment(store)
                .onAppear { appDelegate.attach(store) }
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Yenile") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
                .onAppear { appDelegate.attach(store) }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(store)
        }
    }

    /// Screenshot runs pass `-demo-panel` to see the menu bar panel in the window.
    @ViewBuilder
    private var mainContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo-panel") {
            MenuBarPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            MacRootView()
                .frame(minWidth: 760, minHeight: 480)
        }
        #else
        MacRootView()
            .frame(minWidth: 760, minHeight: 480)
        #endif
    }
}

/// Keeps the data fresh while PickUp sits in the menu bar all day, and handles notification
/// actions (Devam et, 1 saat ertele, Bitti).
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var store: AppStore?
    private var refreshLoop: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Reminders.registerCategories()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    /// Closing the window keeps PickUp in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshNow()
    }

    @MainActor
    func attach(_ store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        refreshLoop?.cancel()
        refreshLoop = Task { [weak store] in
            while !Task.isCancelled {
                await store?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @objc private func didWake() {
        refreshNow()
    }

    private func refreshNow() {
        Task { @MainActor in await self.store?.refresh() }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else { return }
        let action = response.actionIdentifier
        await handle(action: action, taskID: taskID)
    }

    @MainActor
    private func handle(action: String, taskID: String) async {
        await store?.handleNotification(action: action, taskID: taskID)
    }
}
