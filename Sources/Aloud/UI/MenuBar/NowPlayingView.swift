import SwiftUI
import KeyboardShortcuts

struct NowPlayingView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed directly, same reason as SettingsView: AppCoordinator
    // doesn't re-publish when these nested ObservableObjects change.
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject private var settings = SettingsStore.shared
    var onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The play/pause button is a solid accent-filled circle; the icon on
    /// top needs to flip between white and near-black depending on which
    /// direction the accent color goes — dark mode's bright teal fill
    /// measured ~1.8:1 contrast with a white icon (fails even the relaxed
    /// 3:1 bar for icons), so light-on-dark-fill and dark-on-light-fill
    /// each need their own icon color rather than a single fixed white.
    private var onAccentIconColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.82) : .white
    }

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

    private var isActive: Bool { coordinator.activityState != .idle }
    /// A finished read leaves its caption in place so it can be replayed —
    /// this mirrors that same signal to decide whether Play should be
    /// enabled even while idle.
    private var canReplay: Bool { !coordinator.currentChunkText.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(voiceDisplayName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    // .primary, not accentColor — accent-as-text on its own
                    // light tint measured ~2.9:1, under the 4.5:1 AA bar for
                    // normal-size text. The capsule tint still carries the
                    // brand color; the text just needs to stay legible.
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voice: \(voiceDisplayName). Open Settings.")

                Spacer()

                if isActive {
                    MiniWaveform(isAnimating: audioPlayer.isPlaying)
                }

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            captionCard

            HStack(spacing: 12) {
                Button(action: coordinator.togglePlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(onAccentIconColor)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(!isActive && !canReplay)
                .opacity((isActive || canReplay) ? 1 : 0.4)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : (isActive ? "Play" : "Replay"))

                Button(action: coordinator.stopReading) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(!isActive)
                .opacity(isActive ? 1 : 0.4)
                .accessibilityLabel("Stop")

                Spacer()

                Button(action: onOpenSettings) {
                    Text(String(format: "%.1f×", settings.speed))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed: \(String(format: "%.1f×", settings.speed)). Open Settings.")
            }
        }
        .onChange(of: audioPlayer.activeWordIndex) { _, newValue in
            updateWindow(for: newValue)
        }
        .onChange(of: audioPlayer.currentWords.map(\.id)) { _, _ in
            windowStart = 0
        }
    }

    private var captionCard: some View {
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
                    .lineLimit(4)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82, alignment: .topLeading)
        .clipped()
        .cardBackground()
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
                    // Dark text on the yellow highlight regardless of
                    // light/dark mode — `.primary` would go near-white in
                    // dark mode, which is poor contrast on a bright
                    // highlight (the classic "white text on yellow"
                    // problem). A highlighter pen is always dark ink
                    // under bright yellow; same idea here.
                    .foregroundStyle(isActive ? Color.black.opacity(0.82) : Color.secondary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isActive ? Color.yellow.opacity(0.65) : Color.clear)
                    )
            }
        }
    }
}
