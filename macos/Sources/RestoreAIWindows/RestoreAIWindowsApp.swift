import SwiftUI

@main
struct RestoreAIWindowsApp: App {
    @StateObject private var store = SnapshotStore()
    @StateObject private var runner = ActionRunner()

    var body: some Scene {
        WindowGroup("Restore AI Windows") {
            ContentView()
                .environmentObject(store)
                .environmentObject(runner)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Restore AI Windows", systemImage: "arrow.triangle.2.circlepath") {
            Button("Restore Now") { runner.restoreNow(includeBrowser: true) }
            Button("Snapshot Now") { runner.snapshotNow() }
            Divider()
            Button("Open Window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
