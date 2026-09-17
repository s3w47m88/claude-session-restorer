import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var runner: ActionRunner
    @AppStorage("restoreBrowserWindows") private var restoreBrowser = true
    @State private var selectedSessions: Set<String> = []
    @State private var showSessionPicker = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

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
        .frame(minWidth: 460, minHeight: 580)
        .onAppear {
            runner.requestNotificationPermission()
            store.reload()
            // Pre-select all sessions by default
            for project in store.projects {
                for session in project.sessions {
                    selectedSessions.insert(session.id)
                }
            }
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
                detail: "needed to restore each window's virtual desktop (Space)",
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
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Also restore browser windows", isOn: $restoreBrowser)

            HStack {
                if !store.projects.isEmpty {
                    Button {
                        showSessionPicker.toggle()
                    } label: {
                        Label(showSessionPicker ? "Hide sessions" : "Choose sessions", systemImage: "checkmark.circle")
                    }
                    .disabled(runner.isRunning)
                }

                Button {
                    runner.restoreNow(includeBrowser: restoreBrowser, selectedSessions: Array(selectedSessions))
                } label: {
                    Label("Restore Now", systemImage: "play.fill")
                }
                .disabled(runner.isRunning || selectedSessions.isEmpty)

                Button {
                    runner.snapshotNow()
                    store.reload()
                } label: {
                    Label("Snapshot Now", systemImage: "camera.fill")
                }
                .disabled(runner.isRunning)

                Spacer()

                if runner.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            Button {
                runner.runInstaller()
            } label: {
                Label("Run installer / repair", systemImage: "wrench.and.screwdriver")
            }
            .disabled(runner.isRunning)
        }
    }
}
