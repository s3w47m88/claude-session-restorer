import SwiftUI

@main
struct RestoreAIWindowsApp: App {
    @StateObject private var store = SnapshotStore()
    @StateObject private var runner = ActionRunner()
    @StateObject private var progress = ProgressStore()

    init() {
        // Watched for the app's whole lifetime, not just while the window is
        // open, so the temporary menu-bar item works with the window closed.
        _progress.wrappedValue.startWatching()
    }

    var body: some Scene {
        WindowGroup("Restore AI Windows") {
            ContentView()
                .environmentObject(store)
                .environmentObject(runner)
                .environmentObject(progress)
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

        // Temporary menu-bar item, visible only while a restore is running, so
        // progress is visible without the app window focused.
        MenuBarExtra(isInserted: $progress.isVisible) {
            Text(progress.current)
            Text("\(Int(progress.fraction * 100))% complete")
        } label: {
            Text("\(Int(progress.fraction * 100))%")
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
