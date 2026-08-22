import AVFoundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentChunkIndex = 0
    @Published private(set) var totalChunks = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var scheduledCount = 0
    private var pendingBuffers = 0
    private var isScheduleComplete = false
    private var onAllChunksFinished: (() -> Void)?

    enum PlayerError: LocalizedError {
        case bufferCreationFailed
        var errorDescription: String? { "Couldn't create an audio buffer for playback." }
    }

    init() {
        engine.attach(playerNode)
    }

    /// Call before enqueueing the first chunk of a new read.
    func reset(totalChunks: Int, onFinished: @escaping () -> Void) {
        stop()
        self.totalChunks = totalChunks
        currentChunkIndex = 0
        scheduledCount = 0
        pendingBuffers = 0
        isScheduleComplete = false
        onAllChunksFinished = onFinished
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

        scheduledCount += 1
        pendingBuffers += 1
        let chunkNumber = scheduledCount
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.currentChunkIndex = chunkNumber
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
    func finishSchedule() {
        isScheduleComplete = true
        checkFinished()
    }

    private func checkFinished() {
        guard isScheduleComplete, pendingBuffers == 0 else { return }
        isPlaying = false
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
        playerNode.stop()
        engine.stop()
        isPlaying = false
        scheduledCount = 0
        pendingBuffers = 0
        isScheduleComplete = false
    }
}
