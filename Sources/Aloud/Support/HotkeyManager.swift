import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let readSelection = Self("readSelection", default: .init(.space, modifiers: [.control, .option]))
}
