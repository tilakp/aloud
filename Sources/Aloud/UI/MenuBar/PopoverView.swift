import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var showSettings = false
    var onScreenChange: (Bool) -> Void

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onBack: {
                    showSettings = false
                    onScreenChange(false)
                })
            } else {
                NowPlayingView(audioPlayer: coordinator.audioPlayer, onOpenSettings: {
                    showSettings = true
                    onScreenChange(true)
                })
            }
        }
        .padding(16)
        .frame(
            width: PopoverSize.nowPlaying.width,
            height: showSettings ? PopoverSize.settings.height : PopoverSize.nowPlaying.height,
            alignment: .top
        )
    }
}
