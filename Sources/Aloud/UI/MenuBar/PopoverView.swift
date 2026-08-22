import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onBack: { showSettings = false })
            } else {
                NowPlayingView(audioPlayer: coordinator.audioPlayer, onOpenSettings: { showSettings = true })
            }
        }
        .padding(14)
        .frame(width: 292)
    }
}
