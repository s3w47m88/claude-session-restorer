import Foundation
@preconcurrency import UserNotifications

@MainActor
final class ActionRunner: ObservableObject {
    @Published var isRunning = false
    @Published var lastResult: String?
    @Published var lastFailed = false

    func restoreNow(includeBrowser: Bool, selectedSessions: [String] = []) {
        run(label: "Restore") {
            var env: [String: String] = [:]
            if !includeBrowser { env["RESTORE_SKIP_BROWSER"] = "1" }
            if !selectedSessions.isEmpty {
                env["RESTORE_SESSION_FILTER"] = selectedSessions.joined(separator: ",")
            }
            return try Engine.run(script: "claude-session-restore.sh", args: ["--force"], env: env)
        }
    }

    func snapshotNow() {
        run(label: "Snapshot") {
            try Engine.run(script: "claude-session-snapshot.sh")
        }
    }

    func runInstaller() {
        run(label: "Install/Repair") {
            // install.sh lives at the repo root, one level above the engine's scripts dir
            // when running from the bundle; fall back to a sibling of scripts dir otherwise.
            let candidates = [
                Engine.scriptsDir.deletingLastPathComponent().appendingPathComponent("install.sh"),
                Engine.scriptsDir.appendingPathComponent("../install.sh").standardized
            ]
            guard let installer = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw Engine.EngineError.scriptMissing("install.sh", candidates.first?.path ?? "?")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [installer.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Engine.RunResult(output: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
        }
    }

    private func run(label: String, _ work: @escaping () throws -> Engine.RunResult) {
        isRunning = true
        lastResult = nil
        Task {
            do {
                let result = try await Task.detached { try work() }.value
                self.isRunning = false
                self.lastFailed = result.exitCode != 0
                self.lastResult = "\(label) \(result.exitCode == 0 ? "succeeded" : "failed (exit \(result.exitCode))")"
                self.notify(title: "Restore AI Windows", body: self.lastResult ?? label)
            } catch {
                self.isRunning = false
                self.lastFailed = true
                self.lastResult = "\(label) failed: \(error.localizedDescription)"
                self.notify(title: "Restore AI Windows", body: self.lastResult ?? label)
            }
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
