import SwiftUI

@main
struct CleanLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            ContentView()
                .cleanLocalEnvironment(environment)
                .task {
                    appDelegate.environment = environment
                    await environment.bootstrap()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(environment: environment) }

        WindowGroup("Preview", id: MediaPreviewScene.id, for: MediaItem.ID.self) { $itemID in
            MediaPreviewWindow(itemID: itemID)
                .cleanLocalEnvironment(environment)
        }
        .defaultSize(width: 1100, height: 760)
        .commandsRemoved()

        Settings {
            SettingsView()
                .cleanLocalEnvironment(environment)
                .frame(width: 680, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var environment: AppEnvironment?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Balance every security-scoped access grant before exiting.
        environment?.library.shutdown()
    }
}
