import SwiftUI

@main
struct GunceApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(Self.forcedColorScheme)
        }
    }

    /// Screenshot runs pass `-demo-dark` to capture Dark Mode. Release builds never force it.
    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo-dark") { return .dark }
        #endif
        return nil
    }
}
