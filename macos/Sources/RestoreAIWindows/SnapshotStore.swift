import Foundation
import Combine

struct ProjectSessions: Identifiable {
    var id: String { project }
    let project: String
    let sessionCount: Int
}

struct BrowserWindowInfo: Identifiable {
    let id: Int
    let tabCount: Int
    let spaceId: String
}

@MainActor
final class SnapshotStore: ObservableObject {
    @Published var projects: [ProjectSessions] = []
    @Published var browserWindows: [BrowserWindowInfo] = []
    @Published var lastUpdated: Date?
    @Published var hasSnapshot = false

    func reload() {
        let stateDir = Engine.sessionStateDir
        let activePath = stateDir.appendingPathComponent("active.tsv")
        let browserPath = stateDir.appendingPathComponent("browser.tsv")

        var found = false

        if let text = try? String(contentsOf: activePath, encoding: .utf8) {
            found = true
            var counts: [String: Int] = [:]
            var order: [String] = []
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 1)
                guard cols.count == 2 else { continue }
                let cwd = String(cols[1])
                let project = (cwd as NSString).lastPathComponent
                if counts[project] == nil { order.append(project) }
                counts[project, default: 0] += 1
            }
            projects = order.map { ProjectSessions(project: $0, sessionCount: counts[$0] ?? 0) }
        } else {
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
        if let attrs = try? FileManager.default.attributesOfItem(atPath: activePath.path),
           let modDate = attrs[.modificationDate] as? Date {
            lastUpdated = modDate
        } else {
            lastUpdated = nil
        }
    }
}
