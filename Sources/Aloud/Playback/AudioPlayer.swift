import AVFoundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var scheduledCount = 0
    private var pendingBuffers = 0
    private var isScheduleComplete = false
    private var onAllChunksFinished: (() -> Void)?

    /// Bumped by every `stop()` (so by every `reset()` too, which calls
    /// it). `AVAudioPlayerNode` fires a buffer's completion handler when
    /// playback is stopped, not just when the buffer finishes playing —
    /// including for buffers left over from whatever read was just
    /// interrupted. Those handlers are dispatched onto the main queue and
    /// land *after* `stop()`/`reset()` has already zeroed `pendingBuffers`
    /// for the new read, so without this guard they'd decrement the new
    /// read's counter for buffers that belonged to the old one — it could
    /// go negative and never legitimately hit exactly 0 again, leaving
    /// the "all done" check (and the status icon animation) stuck
    /// forever. Every async completion callback checks it was scheduled
    /// in the generation that's still current before touching state.
    private var generation = 0

    enum PlayerError: LocalizedError {
        case bufferCreationFailed
        var errorDescription: String? { "Couldn't create an audio buffer for playback." }
    }

    init() {
        engine.attach(playerNode)
    }

    /// Call before enqueueing the first chunk of a new read. Returns the
    /// generation token for this read — pass it back to `finishSchedule`
    /// so a stale synthesis task from an interrupted read can't mark the
    /// wrong read's schedule complete.
    @discardableResult
    func reset(onFinished: @escaping () -> Void) -> Int {
        stop()
        onAllChunksFinished = onFinished
        return generation
    }

    func enqueue(samples: [Float], sampleRate: Double) throws {
        // A chunk that synthesizes to zero frames (e.g. punctuation-only
        // text) would otherwise force-unwrap a nil baseAddress below.
        guard !samples.isEmpty else { return }

        let format = self.format ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        self.format = format

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw PlayerError.bufferCreationFailed
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }

        if !engine.isRunning {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            try engine.start()
        }

        // The player already ran out of audio before this chunk was ready,
        // so the listener heard a silent gap.
        if scheduledCount > 0 && pendingBuffers == 0 {
            NSLog("[Aloud][perf] playback gap before chunk \(scheduledCount + 1)")
        }

        scheduledCount += 1
        pendingBuffers += 1
        let scheduledGeneration = generation

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == scheduledGeneration else { return }
                self.pendingBuffers -= 1
                self.checkFinished()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
            isPlaying = true
        }
    }

    /// Call once the synthesis loop has finished attempting every chunk —
    /// whether all of them enqueued successfully or some were skipped.
    /// Without this, a skipped chunk left completion permanently
    /// unreachable: it was gated on `scheduledCount >= totalChunks`, but a
    /// skipped chunk never advances `scheduledCount`, which is only
    /// incremented for chunks that actually enqueue.
    ///
    /// - Parameter generation: the token returned by the `reset()` call
    ///   that started this read. If a newer read has started since (this
    ///   read was interrupted), the call is ignored — otherwise a
    ///   cancelled synthesis task finishing its last iteration could mark
    ///   a completely different, newer read's schedule complete.
    func finishSchedule(generation: Int) {
        guard generation == self.generation else { return }
        isScheduleComplete = true
        checkFinished()
    }

    private func checkFinished() {
        guard isScheduleComplete, pendingBuffers == 0 else { return }
        isPlaying = false
        // A running engine keeps the output device awake even with nothing
        // queued. The next read's enqueue() starts it again.
        playerNode.stop()
        engine.stop()
        onAllChunksFinished?()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func resume() {
        guard engine.isRunning else { return }
        playerNode.play()
        isPlaying = true
    }

    func stop() {
        generation += 1
        playerNode.stop()
        engine.stop()
        isPlaying = false
        scheduledCount = 0
        pendingBuffers = 0
        isScheduleComplete = false
    }
}
