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

        // Debug hook: `ALOUD_DEBUG_TEST_READ=1 open Aloud.app --args` isn't
        // enough to pass env vars through `open`, so this is launched via
        // the binary directly with the env var set. Lets the pipeline be
        // exercised and inspected (DebugAudioDump) without a manual click.
        if ProcessInfo.processInfo.environment["ALOUD_DEBUG_TEST_READ"] != nil {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                coordinator.readText(
                    "The quarterly numbers came in well ahead of forecast, and margins held steady despite the added freight cost."
                )
            }
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
