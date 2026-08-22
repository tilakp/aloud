import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var selectedVoice: String {
        didSet { UserDefaults.standard.set(selectedVoice, forKey: Keys.selectedVoice) }
    }

    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if !LoginItemManager.setEnabled(launchAtLogin) {
                // Registration with the system failed — flip the toggle
                // back rather than let it show a state that isn't real
                // (this app is ad-hoc signed, not installed via a signed
                // installer, which is exactly the situation where
                // SMAppService registration can fail).
                isRevertingLaunchAtLogin = true
                launchAtLogin.toggle()
                UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
                isRevertingLaunchAtLogin = false
            }
        }
    }

    private var isRevertingLaunchAtLogin = false

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private enum Keys {
        static let selectedVoice = "selectedVoice"
        static let speed = "speed"
        static let launchAtLogin = "launchAtLogin"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private init() {
        let defaults = UserDefaults.standard
        selectedVoice = defaults.string(forKey: Keys.selectedVoice) ?? "af_heart"
        speed = defaults.object(forKey: Keys.speed) as? Double ?? 1.0
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }
}

enum LoginItemManager {
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[Aloud] LoginItemManager failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
            return false
        }
    }
}
