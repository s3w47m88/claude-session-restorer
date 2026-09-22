import SwiftUI

@main
struct RestoreAIWindowsApp: App {
    @StateObject private var store = SnapshotStore()
    @StateObject private var runner = ActionRunner()
    @StateObject private var progress = ProgressStore()

    var body: some Scene {
        WindowGroup("Restore AI Windows") {
            ContentView()
                .environmentObject(store)
                .environmentObject(runner)
                .environmentObject(progress)
        }
        // Deliberately resizable: pinned to the content size the window grew
        // taller than the screen and the scroll view had nothing left to scroll.
        .defaultSize(width: 660, height: 760)

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
        //
        // `isInserted` takes a read-only binding on purpose. Handing it a
        // writable one (`$progress.isVisible`) let SwiftUI write back into the
        // published property while rendering, which spun the view graph in an
        // endless "AttributeGraph: cycle detected" loop: the window stopped
        // scrolling and resizing, and the app burned CPU doing nothing.
        MenuBarExtra(isInserted: .constant(progress.isVisible)) {
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
