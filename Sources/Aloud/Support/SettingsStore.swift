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
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LoginItemManager.setEnabled(launchAtLogin)
        }
    }

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
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LoginItemManager: \(error.localizedDescription)")
        }
    }
}
