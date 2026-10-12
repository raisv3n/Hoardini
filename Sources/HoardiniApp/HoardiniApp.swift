import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?

    // Closing the window keeps downloading; the menu bar item stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}

@main
struct HoardiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager = DownloadManager()

    var body: some Scene {
        Window("Hoardini", id: "main") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(manager.settings)
                .onAppear { delegate.onQuit = { manager.shutdown() } }
        }
        MenuBarExtra {
            MenuBarContent().environmentObject(manager)
        } label: {
            let active = manager.items.filter { $0.status == .downloading }.count
            HStack(spacing: 3) {
                if let icon = Brand.image("menubar", points: 18) {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                if active > 0 { Text("\(active)") }
            }
        }
    }
}
