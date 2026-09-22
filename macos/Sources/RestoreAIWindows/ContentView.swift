import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var runner: ActionRunner
    @EnvironmentObject var progress: ProgressStore
    @AppStorage("restoreBrowserWindows") private var restoreBrowser = true
    @State private var selectedSessions: Set<String> = []
    @State private var showSessionPicker = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if progress.isVisible {
                    GroupBox("Restore in progress") {
                        restoreProgress
                    }
                }

                GroupBox("Last snapshot") {
                    snapshotSummary
                }

                if !store.projects.isEmpty && showSessionPicker {
                    GroupBox("Select sessions to restore") {
                        sessionPicker
                    }
                }

                GroupBox("Permissions") {
                    permissionsList
                }

                GroupBox("Actions") {
                    actions
                }

                if let result = runner.lastResult {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(runner.lastFailed ? .red : .green)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear {
            runner.requestNotificationPermission()
            store.reload()
            store.startWatching()
            // Pre-select all sessions by default
            for project in store.projects {
                for session in project.sessions {
                    selectedSessions.insert(session.id)
                }
            }
        }
        .onDisappear {
            store.stopWatching()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
            VStack(alignment: .leading) {
                Text("Restore AI Windows").font(.title2).bold()
                Text("Reopens your Claude Code and browser sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var restoreProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
            Text(progress.current)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var snapshotSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.hasSnapshot {
                Text("No snapshot yet.").foregroundStyle(.secondary)
            } else {
                if let updated = store.lastUpdated {
                    Text("Captured \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let windowCount = store.windowCount, let tabCount = store.tabCount {
                    let sessionCount = store.projects.reduce(0) { $0 + $1.sessionCount }
                    Label(
                        "\(windowCount) window\(windowCount == 1 ? "" : "s"), "
                        + "\(tabCount) tab\(tabCount == 1 ? "" : "s"), "
                        + "\(sessionCount) session\(sessionCount == 1 ? "" : "s")",
                        systemImage: "square.grid.2x2"
                    )
                }
                if store.projects.isEmpty {
                    Text("No iTerm sessions captured.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.projects) { p in
                        Label("\(p.project) — \(p.sessionCount) session\(p.sessionCount == 1 ? "" : "s")",
                              systemImage: "terminal")
                    }
                }
                if !store.browserWindows.isEmpty {
                    Divider()
                    ForEach(store.browserWindows) { w in
                        Label("Browser window \(w.id) — \(w.tabCount) tabs", systemImage: "safari")
                    }
                }
            }
        }
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.projects) { project in
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.project).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    ForEach(project.sessions) { session in
                        HStack {
                            Image(systemName: selectedSessions.contains(session.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedSessions.contains(session.id) ? .blue : .gray)
                                .onTapGesture {
                                    if selectedSessions.contains(session.id) {
                                        selectedSessions.remove(session.id)
                                    } else {
                                        selectedSessions.insert(session.id)
                                    }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.id.prefix(8).uppercased()).font(.caption).monospaced()
                                Text(session.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if session.handoffPath != nil {
                                    Label("has summary", systemImage: "doc.text").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    Divider()
                }
            }
        }
    }

    private var permissionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                name: "Screen Recording",
                // Space (virtual desktop) lookup uses a separate private API and works
                // fine without this. Without it, only window TITLES read back empty —
                // window ids and Spaces still resolve correctly.
                detail: "needed to read window titles; Space (desktop) placement works either way",
                granted: Permissions.screenRecordingGranted,
                openSettings: Permissions.openScreenRecordingSettings
            )
            permissionRow(
                name: "Automation / Apple Events",
                detail: "needed to drive iTerm2 and the browser",
                granted: Permissions.automationLikelyGranted,
                openSettings: Permissions.openAutomationSettings
            )
        }
    }

    private func permissionRow(name: String, detail: String, granted: Bool, openSettings: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: openSettings)
                    .help("Opens System Settings to the \(name) page so you can grant this app access. Nothing is restored or changed until you flip the switch there yourself.")
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Also restore browser windows", isOn: $restoreBrowser)
                .help("When on, Restore Now also reopens your browser windows and tabs from the last snapshot, alongside the Claude Code sessions. When off, only the Claude Code sessions are restored.")

            HStack(spacing: 8) {
                if !store.projects.isEmpty {
                    Button {
                        showSessionPicker.toggle()
                    } label: {
                        Label(showSessionPicker ? "Hide sessions" : "Choose sessions", systemImage: "checkmark.circle")
                    }
                    .disabled(runner.isRunning)
                    .help("Shows or hides the list of captured Claude Code sessions above, where you can check or uncheck which ones to restore. Nothing is restored or changed by opening this list.")
                }

                Button {
                    runner.restoreNow(includeBrowser: restoreBrowser, selectedSessions: Array(selectedSessions))
                } label: {
                    Label("Restore Now", systemImage: "play.fill")
                }
                .disabled(runner.isRunning || selectedSessions.isEmpty)
                .help("Reopens iTerm windows, tabs, and the checked Claude Code sessions from your last snapshot, resuming each one where it left off. This can take a few minutes; watch the progress bar above or the menu-bar icon.")

                Button {
                    runner.snapshotNow { store.reload() }
                } label: {
                    Label("Snapshot Now", systemImage: "camera.fill")
                }
                .disabled(runner.isRunning)
                .help("Records your open iTerm windows, tabs and Claude sessions to disk. Nothing on screen changes; the 'Last snapshot' section above updates when it finishes.")

                Button {
                    runner.runInstaller()
                } label: {
                    Label("Run installer / repair", systemImage: "wrench.and.screwdriver")
                }
                .disabled(runner.isRunning)
                .help("Reinstalls or repairs the background scripts this app relies on, for when a Restore or Snapshot has started failing. It does not touch your iTerm windows or Claude sessions.")

                Spacer()

                if runner.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}
