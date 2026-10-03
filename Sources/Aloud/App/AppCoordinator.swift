import AppKit
import KeyboardShortcuts

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    enum ActivityState: Equatable {
        case idle
        case active
    }

    @Published private(set) var activityState: ActivityState = .idle
    /// Why the last hotkey press didn't start a read. Shown at the top of
    /// the menu until the next read starts.
    private(set) var errorMessage: String?

    let audioPlayer = AudioPlayer()
    var settings = SettingsStore.shared

    private var chunks: [String] = []
    private var synthesisTask: Task<Void, Never>?
    /// The full text of the last non-preview read, kept so the menu's
    /// Play item can replay it once the read has finished.
    private var lastReadText: String?

    var canReplay: Bool { lastReadText != nil }

    private init() {
        KeyboardShortcuts.onKeyUp(for: .readSelection) { [weak self] in
            self?.readCurrentSelection()
        }
    }

    /// Fired by the global hotkey. Flips the status icon to `.active`
    /// immediately, so a press always gets instant feedback.
    func readCurrentSelection() {
        let pressedAt = ContinuousClock.now
        activityState = .active
        errorMessage = nil

        Task {
            do {
                let text = try await SelectionCapture.captureSelectedText()
                NSLog("[Aloud][perf] capture took \(milliseconds(since: pressedAt)) ms")
                startReading(text: text, voice: settings.selectedVoice, speed: Float(settings.speed), startedAt: pressedAt)
            } catch SelectionCapture.CaptureError.permissionDenied {
                fail("Aloud needs Accessibility access.")
            } catch {
                fail("No text selected.")
            }
        }
    }

    /// There's no window to show an error in, so a failed press beeps and
    /// leaves the reason at the top of the menu.
    private func fail(_ message: String) {
        activityState = .idle
        errorMessage = message
        NSSound.beep()
    }

    /// Reads arbitrary text — used by the "Say something" onboarding test
    /// read, and to replay the last read from `togglePlayPause()`.
    func readText(_ text: String) {
        activityState = .active
        errorMessage = nil
        startReading(text: text, voice: settings.selectedVoice, speed: Float(settings.speed))
    }

    /// Reads a short sample in the given voice, so choosing a voice in the
    /// menu lets you hear it.
    func previewVoice(_ voiceID: String) {
        activityState = .active
        errorMessage = nil
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
    }

    /// Runs one short synthesis once the models are loaded, so the first
    /// real read after launch doesn't pay for the first-inference warm-up.
    func preloadEngine() async {
        guard ModelManager.shared.state == .installed else { return }
        let start = ContinuousClock.now
        do {
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

        if !isPreview {
            lastReadText = text
        }
        let generation = audioPlayer.reset { [weak self] in
            self?.activityState = .idle
        }

        let chunksToRead = chunks
        synthesisTask = Task {
            do {
                let loadStart = ContinuousClock.now
                let wasLoaded = await KokoroEngine.shared.isLoaded
                try await KokoroEngine.shared.load()
                if !wasLoaded {
                    NSLog("[Aloud][perf] model load took \(milliseconds(since: loadStart)) ms")
                }
            } catch {
                fail("Couldn't load the voice model.")
                return
            }

            var hasStartedAudio = false
            for (index, chunk) in chunksToRead.enumerated() {
                if Task.isCancelled { return }
                do {
                    let synthStart = ContinuousClock.now
                    let samples = try await KokoroEngine.shared.synthesize(text: chunk, voice: voice, speed: speed)
                    let audioMilliseconds = Int(Double(samples.count) / KokoroEngine.sampleRate * 1000)
                    NSLog("[Aloud][perf] chunk \(index + 1)/\(chunksToRead.count): \(chunk.count) chars, synth \(milliseconds(since: synthStart)) ms, audio \(audioMilliseconds) ms")
                    if Task.isCancelled { return }
                    try audioPlayer.enqueue(samples: samples, sampleRate: KokoroEngine.sampleRate)
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
