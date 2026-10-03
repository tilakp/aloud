import AppKit
import ApplicationServices

/// Reads the current text selection from whatever app is frontmost.
///
/// Primary path is the Accessibility API — no clipboard involved. Not every
/// app exposes `kAXSelectedTextAttribute` (some Electron/Chromium-embedded
/// views and custom-drawn text views don't), so when the AX read comes back
/// empty this falls back — invisibly to the user — to a simulated ⌘C +
/// pasteboard read, restoring whatever was on the clipboard before.
enum SelectionCapture {
    enum CaptureError: Error {
        case permissionDenied
        case empty
    }

    static func captureSelectedText() async throws -> String {
        guard PermissionsManager.isTrusted() else {
            NSLog("[Aloud][capture] not trusted for Accessibility")
            throw CaptureError.permissionDenied
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NSLog("[Aloud][capture] frontmost app: \(frontmost)")

        if let text = readViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[Aloud][capture] AX succeeded, \(text.count) chars")
            return text
        }
        NSLog("[Aloud][capture] AX read empty/failed, trying clipboard fallback")

        if let text = try await readViaSimulatedCopy(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[Aloud][capture] clipboard fallback succeeded, \(text.count) chars")
            return text
        }

        NSLog("[Aloud][capture] both AX and clipboard fallback came back empty")
        throw CaptureError.empty
    }

    private static func readViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        // The default timeout is about 6s, so a hung frontmost app would
        // make the hotkey look dead. On the system-wide element this sets
        // the timeout for every AX call this process makes.
        AXUIElementSetMessagingTimeout(systemWide, 1.0)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        NSLog("[Aloud][capture] AX focusedElement result: \(focusResult.rawValue)")
        guard focusResult == .success, let element = focusedElement else { return nil }

        var role: AnyObject?
        _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        NSLog("[Aloud][capture] AX focused element role: \(role as? String ?? "?")")

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText
        )
        NSLog("[Aloud][capture] AX selectedText result: \(textResult.rawValue)")
        guard textResult == .success else { return nil }
        return selectedText as? String
    }

    @MainActor
    private static func readViaSimulatedCopy() async throws -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousSnapshot = snapshotPasteboard(pasteboard)

        simulateCopyKeystroke()

        // Give the frontmost app up to 300ms to respond to the synthetic
        // ⌘C, but read the pasteboard back as soon as the copied string is
        // there. The change count alone isn't enough: an app can clear the
        // pasteboard (bumping the count) a moment before it writes to it.
        var result: String?
        for _ in 0..<20 {
            if pasteboard.changeCount != previousChangeCount, let string = pasteboard.string(forType: .string) {
                result = string
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        NSLog("[Aloud][capture] clipboard changeCount before=\(previousChangeCount) after=\(pasteboard.changeCount) gotString=\(result != nil)")

        restorePasteboard(previousSnapshot, on: pasteboard)
        return result
    }

    /// Every representation of every item, not just one type off the first
    /// item — a plain `.first` capture would silently degrade a multi-item
    /// clipboard (e.g. several Finder files) or a multi-representation one
    /// (e.g. rich text's RTF/HTML/plain-text trio) down to a single value
    /// when restored.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
    }

    private static func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]], on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func simulateCopyKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeC: CGKeyCode = 0x08
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
