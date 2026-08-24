import AVFoundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentChunkIndex = 0
    @Published private(set) var totalChunks = 0

    /// Words of the chunk currently playing, and which one is being
    /// spoken right now — driven by a wall-clock timer against each
    /// chunk's start time, since Kokoro's per-word timestamps are
    /// relative to the start of that chunk's own audio.
    @Published private(set) var currentWords: [SpokenWord] = []
    @Published private(set) var activeWordIndex: Int?

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

    private var wordsByChunk: [Int: [SpokenWord]] = [:]
    private var currentChunkStartDate: Date?
    private var pauseDate: Date?
    private var highlightTimer: Timer?

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
    func reset(totalChunks: Int, onFinished: @escaping () -> Void) -> Int {
        stop()
        self.totalChunks = totalChunks
        currentChunkIndex = 0
        scheduledCount = 0
        pendingBuffers = 0
        isScheduleComplete = false
        wordsByChunk = [:]
        onAllChunksFinished = onFinished
        return generation
    }

    func enqueue(samples: [Float], words: [SpokenWord], sampleRate: Double) throws {
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

        scheduledCount += 1
        pendingBuffers += 1
        let chunkNumber = scheduledCount
        let scheduledGeneration = generation
        wordsByChunk[chunkNumber] = words

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == scheduledGeneration else { return }
                self.currentChunkIndex = chunkNumber
                self.pendingBuffers -= 1
                // This buffer just finished, so — with buffers scheduled
                // back-to-back — the next one is starting right now.
                self.beginChunk(chunkNumber + 1)
                self.checkFinished()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
            isPlaying = true
            beginChunk(chunkNumber)
            startHighlightTimer()
        }
    }

    private func beginChunk(_ number: Int) {
        guard let words = wordsByChunk[number] else {
            currentWords = []
            activeWordIndex = nil
            return
        }
        currentChunkStartDate = Date()
        currentWords = words
        activeWordIndex = nil
    }

    private func startHighlightTimer() {
        guard highlightTimer == nil else { return }
        highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateActiveWord() }
        }
    }

    private func stopHighlightTimer() {
        highlightTimer?.invalidate()
        highlightTimer = nil
    }

    private func updateActiveWord() {
        guard let startDate = currentChunkStartDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)

        if let index = currentWords.firstIndex(where: { word in
            guard let start = word.startTime else { return false }
            return elapsed >= start && elapsed < (word.endTime ?? start)
        }) {
            activeWordIndex = index
        } else if let lastStarted = currentWords.lastIndex(where: { ($0.startTime ?? .infinity) <= elapsed }) {
            // Between two words' precise ranges (e.g. mid-pause) — keep
            // showing the most recent one rather than flickering to none.
            activeWordIndex = lastStarted
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
        stopHighlightTimer()
        onAllChunksFinished?()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        pauseDate = Date()
        stopHighlightTimer()
    }

    func resume() {
        guard engine.isRunning else { return }
        if let pauseDate {
            // The wall-clock kept moving while paused, but playback
            // didn't — shift the chunk's start time forward by exactly
            // how long the pause lasted so elapsed-time math stays
            // correct for word highlighting.
            let pausedDuration = Date().timeIntervalSince(pauseDate)
            currentChunkStartDate = currentChunkStartDate?.addingTimeInterval(pausedDuration)
            self.pauseDate = nil
        }
        playerNode.play()
        isPlaying = true
        startHighlightTimer()
    }

    func stop() {
        generation += 1
        playerNode.stop()
        engine.stop()
        isPlaying = false
        scheduledCount = 0
        pendingBuffers = 0
        isScheduleComplete = false
        currentWords = []
        activeWordIndex = nil
        currentChunkStartDate = nil
        pauseDate = nil
        stopHighlightTimer()
    }
}
