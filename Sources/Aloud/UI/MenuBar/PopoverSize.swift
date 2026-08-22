import AppKit

/// The popover has two fixed sizes, one per screen — Now Playing is short
/// and compact; Settings has enough content (28 voices, several rows) that
/// forcing it into the same short height would mean scrolling to see
/// basic settings like the hotkey or Launch at Login. Switching sizes on
/// navigation (clicking the gear/back) is a deliberate, user-initiated
/// change, unlike the reflow that happens reactively while reading — that
/// distinction is why this doesn't conflict with keeping the panel fixed.
enum PopoverSize {
    static let nowPlaying = NSSize(width: 324, height: 212)
    static let settings = NSSize(width: 324, height: 516)
}
