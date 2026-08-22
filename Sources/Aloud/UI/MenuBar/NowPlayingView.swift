import SwiftUI
import KeyboardShortcuts

struct NowPlayingView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed directly, same reason as SettingsView: AppCoordinator
    // doesn't re-publish when these nested ObservableObjects change.
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject private var settings = SettingsStore.shared
    var onOpenSettings: () -> Void

    /// Index into `audioPlayer.currentWords` where the visible caption
    /// window starts. Deliberately "sticky" rather than recentered on
    /// every word (see `updateWindow`) — words stay put while the
    /// highlight moves across them, and the window only scrolls forward
    /// when the active word gets close to its edge.
    @State private var windowStart = 0
    private let windowSize = 15
    private let windowMargin = 3

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
                } else if !audioPlayer.currentWords.isEmpty {
                    highlightedCaption
                } else {
                    Text(coordinator.currentChunkText)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
            }
            .font(.system(size: 13))
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
        .onChange(of: audioPlayer.activeWordIndex) { _, newValue in
            updateWindow(for: newValue)
        }
        .onChange(of: audioPlayer.currentWords.map(\.id)) { _, _ in
            windowStart = 0
        }
    }

    private var voiceDisplayName: String {
        Voices.byID(coordinator.currentVoice)?.name ?? coordinator.currentVoice
    }

    /// A window of words starting at `windowStart`, rather than the whole
    /// chunk — keeps the caption to a couple of lines regardless of how
    /// long the chunk is.
    private var visibleWords: [(index: Int, word: SpokenWord)] {
        let words = audioPlayer.currentWords
        guard !words.isEmpty else { return [] }
        let start = min(windowStart, max(0, words.count - 1))
        let end = min(words.count, start + windowSize)
        return (start..<end).map { ($0, words[$0]) }
    }

    /// Only advances the window when the active word is about to scroll
    /// past its edge — most word-to-word transitions leave every visible
    /// word exactly where it was, so only the highlight moves. Advancing
    /// on every single word (a naive recenter-on-active approach) would
    /// still shift the whole line's layout on almost every word, which is
    /// the same kind of distracting jitter a font-weight change causes.
    private func updateWindow(for active: Int?) {
        guard let active else { return }
        if active < windowStart + windowMargin {
            windowStart = max(0, active - windowMargin)
        } else if active > windowStart + windowSize - windowMargin {
            windowStart = max(0, active - windowMargin)
        }
    }

    /// Highlights the active word with a background fill rather than a
    /// font-weight change — bolding shifts each word's rendered width,
    /// which reflows the whole line as the highlight moves; a background
    /// doesn't. `Text` concatenation can't carry a per-segment background,
    /// so this lays out each word as its own view via FlowLayout instead.
    private var highlightedCaption: some View {
        FlowLayout(horizontalSpacing: 0, verticalSpacing: 3) {
            ForEach(visibleWords, id: \.index) { entry in
                let isActive = entry.index == audioPlayer.activeWordIndex
                Text(entry.word.text + entry.word.trailingWhitespace)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isActive ? Color.yellow.opacity(0.55) : Color.clear)
                    )
            }
        }
    }
}
