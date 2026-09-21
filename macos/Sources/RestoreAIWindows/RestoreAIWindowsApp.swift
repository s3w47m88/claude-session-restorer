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
            // No blind "Restore Now" here: restoring everything is the expensive
            // path, so the menu bar only opens the picker where sessions are chosen.
            Button("Choose Sessions to Restore…") { openPicker() }
            Button("Snapshot Now") { runner.snapshotNow() }
            Divider()
            Button("Open Window") { openPicker() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private func openPicker() {
        store.reload()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
