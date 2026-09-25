import SwiftUI
import UserNotifications

@main
struct PacerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PacerStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("Pacer", id: WindowID.main) {
            MainView()
                .environment(store)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Window("Pacer Settings", id: WindowID.settings) {
            SettingsView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to Pacer", id: WindowID.setup) {
            SetupView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let presenter = NotificationPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = presenter
        _ = Updater.shared
    }
}
