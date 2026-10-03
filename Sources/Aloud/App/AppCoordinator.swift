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
    /// The full text of the last non-preview read, kept so the Now
    /// Playing panel's Play button can replay it once the read has
    /// finished (rather than only being usable to pause/resume a read
    /// that's still in progress).
    private var lastReadText: String?

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
        let pressedAt = ContinuousClock.now
        activityState = .active
        errorMessage = nil
        currentChunkText = ""

        Task {
            do {
                let text = try await SelectionCapture.captureSelectedText()
                NSLog("[Aloud][perf] capture took \(milliseconds(since: pressedAt)) ms")
                popupRequestID += 1
                startReading(text: text, voice: settings.selectedVoice, speed: Float(settings.speed), startedAt: pressedAt)
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

    /// Reads arbitrary text — used by the "Say something" onboarding test
    /// read, and to replay the last read from `togglePlayPause()`.
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
        guard activityState == .active else {
            // Nothing currently playing/paused to resume — if there's a
            // finished read on hand, treat Play as "replay it".
            if let lastReadText {
                readText(lastReadText)
            }
            return
        }
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

    /// Loads the model and runs one short synthesis, so the first real read
    /// after launch doesn't pay for the weight load and Metal shader
    /// compilation. Uses the default voice so the G2P language is already
    /// the one the next read will most likely need.
    func preloadEngine() async {
        guard ModelManager.shared.state == .installed else { return }
        let start = ContinuousClock.now
        do {
            try await KokoroEngine.shared.load(
                modelURL: ModelManager.shared.modelFileURL,
                voicesURL: ModelManager.shared.voicesFileURL
            )
            _ = try await KokoroEngine.shared.synthesize(text: "Hello.", voice: settings.selectedVoice, speed: 1.0)
            NSLog("[Aloud][perf] engine preload took \(milliseconds(since: start)) ms")
        } catch {
            NSLog("[Aloud][perf] engine preload failed: \(error.localizedDescription)")
        }
    }

    private func startReading(
        text: String,
        voice: String,
        speed: Float,
        isPreview: Bool = false,
        startedAt: ContinuousClock.Instant = .now
    ) {
        synthesisTask?.cancel()
        audioPlayer.stop()

        chunks = TextChunker.chunks(for: text)
        guard !chunks.isEmpty else {
            activityState = .idle
            return
        }

        currentVoice = voice
        if !isPreview {
            lastReadText = text
        }
        let generation = audioPlayer.reset(totalChunks: chunks.count) { [weak self] in
            guard let self else { return }
            activityState = .idle
            // Deliberately leave currentChunkText in place once a read
            // finishes naturally, rather than clearing it — so the
            // caption stays visible and Play can replay it. stopReading()
            // (an explicit Stop) still clears it.
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
                let loadStart = ContinuousClock.now
                let wasLoaded = await KokoroEngine.shared.isLoaded
                try await KokoroEngine.shared.load(
                    modelURL: ModelManager.shared.modelFileURL,
                    voicesURL: ModelManager.shared.voicesFileURL
                )
                if !wasLoaded {
                    NSLog("[Aloud][perf] model load took \(milliseconds(since: loadStart)) ms")
                }
            } catch {
                errorMessage = "Couldn't load the voice model."
                activityState = .idle
                return
            }

            var hasStartedAudio = false
            for (index, chunk) in chunksToRead.enumerated() {
                if Task.isCancelled { return }
                currentChunkText = chunk
                do {
                    let synthStart = ContinuousClock.now
                    let (samples, words) = try await KokoroEngine.shared.synthesize(text: chunk, voice: voice, speed: speed)
                    let audioMilliseconds = Int(Double(samples.count) / KokoroEngine.sampleRate * 1000)
                    NSLog("[Aloud][perf] chunk \(index + 1)/\(chunksToRead.count): \(chunk.count) chars, synth \(milliseconds(since: synthStart)) ms, audio \(audioMilliseconds) ms")
                    if Task.isCancelled { return }
                    try audioPlayer.enqueue(samples: samples, words: words, sampleRate: KokoroEngine.sampleRate)
                    if !hasStartedAudio {
                        hasStartedAudio = true
                        NSLog("[Aloud][perf] first audio after \(milliseconds(since: startedAt)) ms")
                    }
                } catch {
                    // Skip a chunk that fails rather than aborting the whole read.
                    NSLog("[Aloud][perf] chunk \(index + 1) skipped: \(error)")
                    continue
                }
            }
            // Whether every chunk enqueued successfully or some were
            // skipped, the loop is done attempting them — let AudioPlayer
            // know so it can detect completion even when fewer buffers
            // were scheduled than the original chunk count. The
            // generation guard inside finishSchedule keeps a cancelled
            // task (superseded by a newer read) from marking the wrong
            // read's schedule complete.
            audioPlayer.finishSchedule(generation: generation)
        }
    }
}

private func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
}
