import SwiftUI

@main
struct ForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window — the only standard window Forge uses
        Settings {
            SettingsView()
                .environmentObject(appDelegate.moduleRegistry)
                .environmentObject(appDelegate.settingsManager)
        }
    }
}
