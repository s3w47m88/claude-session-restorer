import Foundation

/// Locates and runs the bundled restore/snapshot engine (shell + python scripts).
/// Resolution order:
///   1. Contents/Resources/engine inside the app bundle (packaged copy)
///   2. ~/.claude/scripts (installed copy — used during `swift run` dev, or if
///      the app was launched without a bundled engine)
enum Engine {
    static var bundledDir: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent("engine")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    static var installedDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scripts")
    }

    /// Directory that actually contains the engine scripts right now.
    static var scriptsDir: URL {
        bundledDir ?? installedDir
    }

    static var sessionStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/session-state")
    }

    static func scriptPath(_ name: String) -> String {
        scriptsDir.appendingPathComponent(name).path
    }

    struct RunResult {
        let output: String
        let exitCode: Int32
    }

    /// Runs a bundled shell script (`claude-session-restore.sh`, `claude-session-snapshot.sh`, `install.sh`)
    /// via /bin/bash and returns its combined stdout/stderr.
    @discardableResult
    static func run(script name: String, args: [String] = [], env: [String: String] = [:]) throws -> RunResult {
        let path = scriptPath(name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.scriptMissing(name, path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path] + args

        var processEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { processEnv[k] = v }
        process.environment = processEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return RunResult(output: output, exitCode: process.terminationStatus)
    }

    enum EngineError: LocalizedError {
        case scriptMissing(String, String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let name, let path):
                return "Engine script \(name) not found at \(path). Run the installer to set it up."
            }
        }
    }
}
