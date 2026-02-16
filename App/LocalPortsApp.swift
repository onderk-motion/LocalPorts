import SwiftUI

@main
struct LocalPortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsPanelView()
                .frame(minWidth: 520)
        }
    }
}
