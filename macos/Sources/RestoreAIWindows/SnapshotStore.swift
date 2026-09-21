import Foundation
import Combine

struct ClaudeSession: Identifiable {
    let id: String
    let project: String
    let cwd: String
    let handoffPath: String?
}

struct ProjectSessions: Identifiable {
    var id: String { project }
    let project: String
    let sessions: [ClaudeSession]
    var sessionCount: Int { sessions.count }
}

struct BrowserWindowInfo: Identifiable {
    let id: Int
    let tabCount: Int
    let spaceId: String
}

// MARK: - windows.json (schema v2, scripts/WINDOWS_SCHEMA.md)

private struct WindowsFile: Decodable {
    let capturedAt: String?
    let windows: [WindowEntry]

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case windows
    }
}

private struct WindowEntry: Decodable {
    let windowId: Int
    let title: String?
    let space: Int?
    let tabs: [TabEntry]

    enum CodingKeys: String, CodingKey {
        case windowId = "window_id"
        case title, space, tabs
    }
}

private struct TabEntry: Decodable {
    let index: Int?
    let title: String?
    let sessions: [SessionEntry]
}

private struct SessionEntry: Decodable {
    let cwd: String
    let claudeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case cwd
        case claudeSessionId = "claude_session_id"
    }
}

@MainActor
final class SnapshotStore: ObservableObject {
    @Published var projects: [ProjectSessions] = []
    @Published var browserWindows: [BrowserWindowInfo] = []
    @Published var lastUpdated: Date?
    @Published var hasSnapshot = false

    /// Scope summary from windows.json — nil when that file is absent and the
    /// old active.tsv-only display is being used instead.
    @Published var windowCount: Int?
    @Published var tabCount: Int?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    /// Watches ~/.claude/session-state/ for changes and reloads on any write,
    /// so the panel stays live while the window is open instead of showing a
    /// snapshot from whenever it happened to appear.
    func startWatching() {
        stopWatching()
        let dir = Engine.sessionStateDir
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedFD, fd >= 0 { close(fd) }
        }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }

    func reload() {
        let stateDir = Engine.sessionStateDir
        let activePath = stateDir.appendingPathComponent("active.tsv")
        let browserPath = stateDir.appendingPathComponent("browser.tsv")
        let windowsPath = stateDir.appendingPathComponent("windows.json")
        let handoffDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/handoffs")

        var found = false
        var sourcePath = activePath

        if let data = try? Data(contentsOf: windowsPath),
           let file = try? JSONDecoder().decode(WindowsFile.self, from: data) {
            found = true
            sourcePath = windowsPath
            windowCount = file.windows.count
            tabCount = file.windows.reduce(0) { $0 + $1.tabs.count }

            var projectMap: [String: [ClaudeSession]] = [:]
            var order: [String] = []
            for window in file.windows {
                for tab in window.tabs {
                    for sessionEntry in tab.sessions {
                        guard let sessionId = sessionEntry.claudeSessionId else { continue }
                        let cwd = sessionEntry.cwd
                        let project = (cwd as NSString).lastPathComponent
                        let handoffPath = handoffPath(for: cwd, handoffDir: handoffDir)
                        let session = ClaudeSession(
                            id: sessionId,
                            project: project,
                            cwd: cwd,
                            handoffPath: handoffPath
                        )
                        if projectMap[project] == nil { order.append(project) }
                        projectMap[project, default: []].append(session)
                    }
                }
            }
            projects = order.map { ProjectSessions(project: $0, sessions: projectMap[$0] ?? []) }
        } else if let text = try? String(contentsOf: activePath, encoding: .utf8) {
            found = true
            windowCount = nil
            tabCount = nil
            var projectMap: [String: [ClaudeSession]] = [:]
            var order: [String] = []
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 1)
                guard cols.count == 2 else { continue }
                let sessionId = String(cols[0])
                let cwd = String(cols[1])
                let project = (cwd as NSString).lastPathComponent
                let handoffPath = handoffPath(for: cwd, handoffDir: handoffDir)

                let session = ClaudeSession(
                    id: sessionId,
                    project: project,
                    cwd: cwd,
                    handoffPath: handoffPath
                )

                if projectMap[project] == nil { order.append(project) }
                projectMap[project, default: []].append(session)
            }
            projects = order.map { ProjectSessions(project: $0, sessions: projectMap[$0] ?? []) }
        } else {
            windowCount = nil
            tabCount = nil
            projects = []
        }

        if let text = try? String(contentsOf: browserPath, encoding: .utf8) {
            found = true
            var rows: [BrowserWindowInfo] = []
            let lines = text.split(separator: "\n")
            for line in lines.dropFirst() { // skip header
                let cols = line.split(separator: "\t")
                guard cols.count >= 7, let idx = Int(cols[0]), let tabs = Int(cols[6]) else { continue }
                rows.append(BrowserWindowInfo(id: idx, tabCount: tabs, spaceId: String(cols[1])))
            }
            browserWindows = rows
        } else {
            browserWindows = []
        }

        hasSnapshot = found
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath.path),
           let modDate = attrs[.modificationDate] as? Date {
            lastUpdated = modDate
        } else {
            lastUpdated = nil
        }
    }

    /// Look up ~/.claude/handoffs/<cwd-slug>.md.
    /// Must match write-handoff.mjs: non-alphanumeric runs -> "-", case preserved.
    private func handoffPath(for cwd: String, handoffDir: URL) -> String? {
        let cwdSlug = cwd
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let path = handoffDir.appendingPathComponent("\(cwdSlug).md").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
