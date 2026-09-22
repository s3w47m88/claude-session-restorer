import Foundation

/// Snapshot of ~/.claude/session-state/restore-progress.json, as written by
/// claude-restore-driver.py. See scripts/PROGRESS_SCHEMA.md for the contract.
private struct RestoreProgressFile: Decodable {
    let state: String
    let updatedAt: String
    let totalWindows: Int
    let totalSessions: Int
    let openedWindows: Int
    let readySessions: Int
    let current: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case state
        case updatedAt = "updated_at"
        case totalWindows = "total_windows"
        case totalSessions = "total_sessions"
        case openedWindows = "opened_windows"
        case readySessions = "ready_sessions"
        case current, error
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoFormatterNoFraction = ISO8601DateFormatter()

private func parseISO8601(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
}

/// Watches ~/.claude/session-state/restore-progress.json and exposes a
/// determinate fraction + human-readable line while a restore is running.
/// Follows scripts/PROGRESS_SCHEMA.md literally: ignores terminal/stale
/// state, never lets the fraction go backwards, renders nothing when the
/// file is absent (the normal idle case).
@MainActor
final class ProgressStore: ObservableObject {
    @Published var isVisible = false
    @Published var fraction: Double = 0
    @Published var current: String = ""

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private static let staleAfter: TimeInterval = 5 * 60

    private var path: URL {
        Engine.sessionStateDir.appendingPathComponent("restore-progress.json")
    }

    /// Reuses SnapshotStore's DispatchSource-on-directory pattern rather than
    /// polling on a timer.
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
        reload()
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }

    func reload() {
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(RestoreProgressFile.self, from: data) else {
            isVisible = false
            return
        }

        guard file.state == "running" else {
            // Terminal state (done/failed) or unknown: show nothing.
            isVisible = false
            return
        }

        if let updated = parseISO8601(file.updatedAt),
           Date().timeIntervalSince(updated) > Self.staleAfter {
            // Dead run: driver was killed without writing a terminal state.
            isVisible = false
            return
        }

        let newFraction: Double
        if file.totalSessions > 0 {
            newFraction = Double(file.readySessions) / Double(file.totalSessions)
        } else if file.totalWindows > 0 {
            newFraction = Double(file.openedWindows) / Double(file.totalWindows)
        } else {
            newFraction = 0
        }
        let clamped = min(1, max(0, newFraction))

        // Never let the fraction go backwards.
        fraction = isVisible ? max(fraction, clamped) : clamped
        current = file.current ?? ""
        isVisible = true
    }
}
