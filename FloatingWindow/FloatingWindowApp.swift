import SwiftUI

@main
struct FloatingWindowApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Buscar actualizaciones…") {
                    appDelegate.checkForUpdates(nil)
                }
            }
        }
    }
}
