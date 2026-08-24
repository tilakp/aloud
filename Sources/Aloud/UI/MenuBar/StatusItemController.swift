import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var popupWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var animationTimer: Timer?
    private var animationFrame = 0

    private let idleImage = StatusIconRenderer.idleImage()
    private let activeFrames = StatusIconRenderer.activeFrames()
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = idleImage
            button.action = #selector(togglePopover)
            button.target = self
        }

        coordinator.$activityState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)

        // Surfaces the popup after a hotkey-triggered read — deliberately
        // *not* driven by activityState (see popupRequestID's doc comment):
        // this only fires once SelectionCapture has already finished
        // reading the frontmost app's selection, so activating our own
        // app here can never race with that capture.
        coordinator.$popupRequestID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if self?.popupWindow == nil {
                    self?.showPopover(activate: false)
                }
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        if let window = popupWindow, window.isVisible {
            closePopover()
        } else {
            showPopover(activate: true)
        }
    }

    /// Positions the popup manually from the status item button's actual
    /// on-screen window frame, rather than using NSPopover's
    /// show(relativeTo:of:) — on this Mac, third-party status items are
    /// hosted out-of-process by Control Center, and NSPopover's automatic
    /// view-relative geometry conversion doesn't resolve correctly against
    /// that hosted button (it opened at an unrelated, seemingly-arbitrary
    /// screen position instead of under the icon). The button's window
    /// frame itself is accurate — the OS still routes clicks to the right
    /// place — so anchoring off that directly sidesteps the bug.
    /// - Parameter activate: whether to also make Aloud the frontmost app.
    ///   True for a direct click on the status item (the user is
    ///   deliberately interacting with Aloud). False for the
    ///   hotkey-triggered auto-show, so the app you were selecting text in
    ///   keeps its focus/frontmost status while the read plays.
    private func showPopover(activate: Bool) {
        guard let coordinator, let button = statusItem.button, let buttonWindow = button.window else { return }

        let popupSize = PopoverSize.nowPlaying
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: popupSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.delegate = self
        // Borderless already removes any resize handle; min==max size
        // additionally blocks any resize that isn't the explicit,
        // deliberate one this class does itself in resizePopover(to:).
        window.minSize = popupSize
        window.maxSize = popupSize

        // A solid, opaque panel rather than the translucent vibrancy
        // material — plain layer-backed NSView, not NSVisualEffectView,
        // since vibrancy is inherently translucent/blurred by design.
        // controlBackgroundColor matches the cards' own fill exactly, so
        // the whole panel reads as one consistent white/adaptive surface
        // with card borders as the only structure, rather than two-toned.
        let container = NSView(frame: NSRect(origin: .zero, size: popupSize))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: PopoverView(onScreenChange: { [weak self] showingSettings in
            self?.resizePopover(showingSettings: showingSettings)
        }).environmentObject(coordinator))
        hosting.frame = NSRect(origin: .zero, size: popupSize)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container

        positionPopover(window, size: popupSize)

        popupWindow = window
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let buttonWindow = self.statusItem.button?.window else { return }
            // A click on the status item button itself is already handled
            // by its own action (togglePopover) — don't race with it here.
            if buttonWindow.frame.contains(NSEvent.mouseLocation) { return }
            self.closePopover()
        }
    }

    /// Positions/sizes `window` so its top edge sits just under the status
    /// item button, for the given `size` — the top edge stays anchored
    /// under the icon while the window grows/shrinks downward.
    private func positionPopover(_ window: NSWindow, size: NSSize, animate: Bool = false) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let screenMaxX = (NSScreen.main?.visibleFrame.maxX ?? buttonFrame.maxX) - 8
        let origin = NSPoint(
            x: min(buttonFrame.midX - size.width / 2, screenMaxX - size.width),
            y: buttonFrame.minY - size.height - 4
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: animate)
    }

    /// Switches the popup between its two fixed sizes when navigating
    /// between Now Playing and Settings — a deliberate, user-initiated
    /// change (unlike the reactive reflow the fixed-size window was
    /// originally built to prevent), so it's fine for this one to animate.
    private func resizePopover(showingSettings: Bool) {
        guard let window = popupWindow else { return }
        let size = showingSettings ? PopoverSize.settings : PopoverSize.nowPlaying
        window.minSize = size
        window.maxSize = size
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        positionPopover(window, size: size, animate: !reduceMotion)
    }

    private func closePopover() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        popupWindow?.close()
        popupWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        popupWindow = nil
    }

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
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.animationFrame = (self.animationFrame + 1) % self.activeFrames.count
                self.setIcon(self.activeFrames[self.animationFrame])
            }
        }
    }

    /// Assigns the button's image and forces an immediate, synchronous
    /// redraw rather than relying on AppKit's normal (coalesced, next
    /// runloop pass) display invalidation. On this Mac, third-party status
    /// items are hosted out-of-process by Control Center (see the note on
    /// `showPopover`), and back-to-back image swaps — the last animation
    /// frame followed almost immediately by the revert to idle, exactly
    /// when a read finishes — could otherwise have their final frame
    /// coalesced away by that out-of-process snapshotting, leaving a stale
    /// animated frame visibly stuck on screen even though this button's
    /// own `image` property (and `activityState`) had already moved on.
    private func setIcon(_ image: NSImage?) {
        guard let button = statusItem.button else { return }
        button.image = image
        button.display()
    }
}
