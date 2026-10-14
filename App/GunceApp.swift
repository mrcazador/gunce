import SwiftUI
import UserNotifications

@main
struct GunceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            content
                .environment(store)
                .preferredColorScheme(Self.forcedColorScheme)
                .onAppear { appDelegate.store = store }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo-widgets") || args.contains("-demo-widgets-idle") {
            WidgetGallery(idle: args.contains("-demo-widgets-idle"))
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }

    /// Screenshot runs pass `-demo-dark` to capture Dark Mode. Release builds never force it.
    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo-dark") { return .dark }
        #endif
        return nil
    }
}

/// Receives notification taps and actions (Devam et, 1 saat ertele, Bitti).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: AppStore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Reminders.registerCategories()
        return true
    }

    /// Show reminders as banners even while the app is open.
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
