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

    private let popupSize = NSSize(width: 324, height: 360)

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

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: PopoverView().environmentObject(coordinator))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        let buttonFrame = buttonWindow.frame
        let screenMaxX = (NSScreen.main?.visibleFrame.maxX ?? buttonFrame.maxX) - 8
        let origin = NSPoint(
            x: min(buttonFrame.midX - popupSize.width / 2, screenMaxX - popupSize.width),
            y: buttonFrame.minY - popupSize.height - 4
        )
        window.setFrameOrigin(origin)

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
            statusItem.button?.image = idleImage
        case .active:
            startAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            statusItem.button?.image = activeFrames.last
            return
        }

        animationFrame = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.animationFrame = (self.animationFrame + 1) % self.activeFrames.count
                self.statusItem.button?.image = self.activeFrames[self.animationFrame]
            }
        }
    }
}
