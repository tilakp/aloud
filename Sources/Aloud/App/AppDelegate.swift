import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var onboardingWindowController: OnboardingWindowController?
    private let coordinator = AppCoordinator.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(coordinator: coordinator)

        if coordinator.settings.hasCompletedOnboarding {
            Task { await ModelManager.shared.ensureInstalled() }
        } else {
            presentOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func presentOnboarding() {
        let controller = OnboardingWindowController { [weak self] in
            guard let self else { return }
            coordinator.settings.hasCompletedOnboarding = true
            onboardingWindowController?.window?.close()
            onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.present()
    }
}
