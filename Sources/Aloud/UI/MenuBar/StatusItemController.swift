import AppKit
import Combine
import KeyboardShortcuts

/// The menu bar icon (animated while a read is in progress) and its menu,
/// which holds every control and setting.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var animationTimer: Timer?
    private var animationFrame = 0

    private let idleImage = StatusIconRenderer.idleImage()
    private let activeFrames = StatusIconRenderer.activeFrames()
    private let coordinator: AppCoordinator
    private let settings = SettingsStore.shared

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = idleImage
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        coordinator.$activityState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu

    /// Rebuilt on every open, so it always shows the current state without
    /// having to observe every value it displays.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let errorMessage = coordinator.errorMessage {
            menu.addItem(disabledItem(errorMessage))
            menu.addItem(.separator())
        }
        if let modelStatus = modelStatusTitle {
            menu.addItem(disabledItem(modelStatus))
            if case .failed = ModelManager.shared.state {
                menu.addItem(item("Retry Download", action: #selector(retryDownload)))
            }
            menu.addItem(.separator())
        }

        let isActive = coordinator.activityState == .active
        let isPlaying = coordinator.audioPlayer.isPlaying
        let play = item(
            isActive ? (isPlaying ? "Pause" : "Resume") : "Replay Last Selection",
            action: #selector(togglePlayPause)
        )
        play.isEnabled = isActive || coordinator.canReplay
        menu.addItem(play)
        let stop = item("Stop", action: #selector(stopReading))
        stop.isEnabled = isActive
        menu.addItem(stop)
        menu.addItem(.separator())

        menu.addItem(voiceMenuItem())
        menu.addItem(speedMenuItem())
        let hotkey = KeyboardShortcuts.getShortcut(for: .readSelection)?.description ?? "none"
        menu.addItem(item("Change Hotkey (\(hotkey))…", action: #selector(changeHotkey)))
        menu.addItem(.separator())

        let launchAtLogin = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchAtLogin.state = settings.launchAtLogin ? .on : .off
        menu.addItem(launchAtLogin)
        if !PermissionsManager.isTrusted() {
            menu.addItem(item("Grant Accessibility Access…", action: #selector(grantAccessibility)))
        }
        menu.addItem(.separator())

        let quit = item("Quit Aloud", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var modelStatusTitle: String? {
        switch ModelManager.shared.state {
        case .installed: nil
        case .notInstalled: "Voice model not installed"
        case .downloading(let fraction):
            "Downloading voice model… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .preparing: "Preparing voices…"
        case .failed: "Voice model download failed"
        }
    }

    private func voiceMenuItem() -> NSMenuItem {
        let name = Voices.byID(settings.selectedVoice)?.name ?? settings.selectedVoice
        let submenu = NSMenu()
        for (group, voices) in Voices.grouped() {
            submenu.addItem(.sectionHeader(title: group.rawValue))
            for voice in voices {
                let voiceItem = item(voice.name, action: #selector(selectVoice(_:)))
                voiceItem.representedObject = voice.id
                voiceItem.state = voice.id == settings.selectedVoice ? .on : .off
                submenu.addItem(voiceItem)
            }
        }
        let parent = NSMenuItem(title: "Voice: \(name)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func speedMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for speed in stride(from: 0.5, through: 2.0, by: 0.1) {
            let speedItem = item(Self.speedLabel(speed), action: #selector(selectSpeed(_:)))
            speedItem.representedObject = speed
            speedItem.state = abs(speed - settings.speed) < 0.01 ? .on : .off
            submenu.addItem(speedItem)
        }
        let parent = NSMenuItem(title: "Speed: \(Self.speedLabel(settings.speed))", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private static func speedLabel(_ speed: Double) -> String {
        String(format: "%.1f×", speed)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    // MARK: - Actions

    @objc private func togglePlayPause() { coordinator.togglePlayPause() }

    @objc private func stopReading() { coordinator.stopReading() }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.selectedVoice = id
        coordinator.previewVoice(id)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Double else { return }
        settings.speed = speed
    }

    /// The recorder can't take keyboard focus while hosted inside the menu
    /// itself, so it gets a small dialog instead.
    @objc private func changeHotkey() {
        let alert = NSAlert()
        alert.messageText = "Change Hotkey"
        alert.informativeText = "Click the field, then press the new shortcut."
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .readSelection)
        recorder.sizeToFit()
        recorder.frame.size.width = 220
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Done")
        NSApp.activate()
        alert.runModal()
    }

    @objc private func toggleLaunchAtLogin() { settings.launchAtLogin.toggle() }

    @objc private func grantAccessibility() {
        PermissionsManager.requestAccess()
        PermissionsManager.openAccessibilitySettings()
    }

    @objc private func retryDownload() {
        Task {
            await ModelManager.shared.ensureInstalled()
            await coordinator.preloadEngine()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Icon

    private func updateIcon(for state: AppCoordinator.ActivityState) {
        switch state {
        case .idle:
            animationTimer?.invalidate()
            animationTimer = nil
            setIcon(idleImage)
        case .active:
            startAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setIcon(activeFrames.last)
            return
        }

        animationFrame = 0
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.animationFrame = (self.animationFrame + 1) % self.activeFrames.count
                self.setIcon(self.activeFrames[self.animationFrame])
            }
        }
        // Common modes, so the icon keeps animating while its menu is open
        // (menu tracking runs the run loop in event-tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Assigns the button's image and forces an immediate, synchronous
    /// redraw rather than relying on AppKit's normal (coalesced, next
    /// runloop pass) display invalidation. On this Mac, third-party status
    /// items are hosted out-of-process by Control Center, and back-to-back
    /// image swaps — the last animation frame followed almost immediately
    /// by the revert to idle, exactly when a read finishes — could
    /// otherwise have their final frame coalesced away by that
    /// out-of-process snapshotting, leaving a stale animated frame visibly
    /// stuck on screen even though this button's own `image` property (and
    /// `activityState`) had already moved on.
    private func setIcon(_ image: NSImage?) {
        guard let button = statusItem.button else { return }
        button.image = image
        button.display()
    }
}
