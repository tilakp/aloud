import Foundation
import KeyboardShortcuts

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    enum ActivityState: Equatable {
        case idle
        case active
    }

    @Published private(set) var activityState: ActivityState = .idle
    @Published private(set) var currentVoice: String = SettingsStore.shared.selectedVoice
    @Published private(set) var currentChunkText = ""
    @Published var errorMessage: String?
    /// Increments whenever the popup should be surfaced. Kept separate from
    /// `activityState` because showing the popup activates our app, and
    /// doing that *before* SelectionCapture reads the frontmost app's
    /// selection races with — and can steal — that app's AX focus, causing
    /// "No text selected" even when text is selected. Only bumped after
    /// capture has already completed (success or failure).
    @Published private(set) var popupRequestID = 0

    let audioPlayer = AudioPlayer()
    var settings = SettingsStore.shared

    private var chunks: [String] = []
    private var synthesisTask: Task<Void, Never>?

    var hasAccessibilityPermission: Bool { PermissionsManager.isTrusted() }

    var modelStatusLabel: String {
        switch ModelManager.shared.state {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .downloading, .verifying: "Installing…"
        case .failed: "Failed"
        }
    }

    private init() {
        KeyboardShortcuts.onKeyUp(for: .readSelection) { [weak self] in
            self?.readCurrentSelection()
        }
    }

    /// Fired by the global hotkey. Flips the status icon to `.active`
    /// immediately (that alone has no focus side effects), but capture
    /// happens before anything else touches window/app activation.
    func readCurrentSelection() {
        activityState = .active
        errorMessage = nil
        currentChunkText = ""

        Task {
            do {
                let text = try await SelectionCapture.captureSelectedText()
                popupRequestID += 1
                startReading(text: text, voice: settings.selectedVoice, speed: Float(settings.speed))
            } catch SelectionCapture.CaptureError.permissionDenied {
                popupRequestID += 1
                activityState = .idle
                errorMessage = "Aloud needs Accessibility access — see Settings."
            } catch {
                // Only now — after we've already tried reading the
                // frontmost app's selection — is it safe to surface our
                // own UI.
                popupRequestID += 1
                activityState = .idle
                errorMessage = "No text selected."
            }
        }
    }

    /// Used by the "Say something" onboarding test read.
    func readText(_ text: String) {
        activityState = .active
        errorMessage = nil
        currentChunkText = ""
        popupRequestID += 1
        startReading(text: text, voice: settings.selectedVoice, speed: Float(settings.speed))
    }

    /// Used by voice-preview buttons in Settings — reads a short sample in
    /// the given voice without changing the default.
    func previewVoice(_ voiceID: String) {
        activityState = .active
        errorMessage = nil
        currentChunkText = ""
        popupRequestID += 1
        let name = Voices.byID(voiceID)?.name ?? voiceID
        startReading(text: "Hi, I'm \(name).", voice: voiceID, speed: 1.0, isPreview: true)
    }

    func togglePlayPause() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.resume()
        }
    }

    func stopReading() {
        synthesisTask?.cancel()
        audioPlayer.stop()
        activityState = .idle
        currentChunkText = ""
    }

    private func startReading(text: String, voice: String, speed: Float, isPreview: Bool = false) {
        synthesisTask?.cancel()
        audioPlayer.stop()

        chunks = TextChunker.chunks(for: text)
        guard !chunks.isEmpty else {
            activityState = .idle
            return
        }

        currentVoice = voice
        audioPlayer.reset(totalChunks: chunks.count) { [weak self] in
            guard let self else { return }
            activityState = .idle
            currentChunkText = ""
            // A preview temporarily shows the previewed voice as "current"
            // in the popover — revert to the real default once it's done,
            // rather than leaving it looking like the default changed.
            if isPreview {
                currentVoice = settings.selectedVoice
            }
        }

        let chunksToRead = chunks
        synthesisTask = Task {
            do {
                try await KokoroEngine.shared.load(
                    modelURL: ModelManager.shared.modelFileURL,
                    voicesURL: ModelManager.shared.voicesFileURL
                )
            } catch {
                errorMessage = "Couldn't load the voice model."
                activityState = .idle
                return
            }

            for chunk in chunksToRead {
                if Task.isCancelled { return }
                currentChunkText = chunk
                do {
                    let (samples, words) = try await KokoroEngine.shared.synthesize(text: chunk, voice: voice, speed: speed)
                    if Task.isCancelled { return }
                    try audioPlayer.enqueue(samples: samples, words: words, sampleRate: KokoroEngine.sampleRate)
                } catch {
                    // Skip a chunk that fails rather than aborting the whole read.
                    continue
                }
            }
            // Whether every chunk enqueued successfully or some were
            // skipped, the loop is done attempting them — let AudioPlayer
            // know so it can detect completion even when fewer buffers
            // were scheduled than the original chunk count.
            audioPlayer.finishSchedule()
        }
    }
}
