import Foundation
import CoreGraphics
import AppKit

enum Permissions {
    /// Screen Recording is required for Space (virtual desktop) restore.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Best-effort check for Automation/Apple Events access to iTerm — there is no
    /// direct query API, so we treat "can we resolve iTerm's Apple Events port" as
    /// a proxy by attempting a harmless, low-risk AppleScript `tell` and reading errors.
    static var automationLikelyGranted: Bool {
        let script = """
        tell application "System Events"
            return (name of processes) is not missing value
        end tell
        """
        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)
        return error == nil
    }

    static func openScreenRecordingSettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAutomationSettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func openPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
