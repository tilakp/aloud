import AppKit
import ApplicationServices

enum PermissionsManager {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccess() -> Bool {
        // Hardcoded rather than referencing the `kAXTrustedCheckOptionPrompt`
        // global directly, which Swift 6 strict concurrency flags as an
        // unsafe shared-mutable-state access even though it's a constant.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
