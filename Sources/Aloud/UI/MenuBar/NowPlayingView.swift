import SwiftUI
import KeyboardShortcuts

struct NowPlayingView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed directly, same reason as SettingsView: AppCoordinator
    // doesn't re-publish when these nested ObservableObjects change.
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject private var settings = SettingsStore.shared
    var onOpenSettings: () -> Void

    private var hotkeyLabel: String {
        KeyboardShortcuts.getShortcut(for: .readSelection)?.description ?? "your hotkey"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(voiceDisplayName, systemImage: "person.wave.2")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)

                Spacer()

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }

            Group {
                if let errorMessage = coordinator.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                } else if coordinator.activityState == .active && coordinator.currentChunkText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading selection…")
                    }
                    .foregroundStyle(.secondary)
                } else if coordinator.currentChunkText.isEmpty {
                    Text("Select text anywhere, then press \(hotkeyLabel).")
                        .foregroundStyle(.secondary)
                } else {
                    Text(coordinator.currentChunkText)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: coordinator.togglePlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activityState == .idle)

                Button(action: coordinator.stopReading) {
                    Image(systemName: "stop.fill")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activityState == .idle)

                Spacer()

                Text(String(format: "%.1f×", settings.speed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var voiceDisplayName: String {
        Voices.byID(coordinator.currentVoice)?.name ?? coordinator.currentVoice
    }
}
