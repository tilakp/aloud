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
        onAllChunksFinished = onFinished
    }

    func enqueue(samples: [Float], sampleRate: Double) throws {
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
        let chunkNumber = scheduledCount
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.currentChunkIndex = chunkNumber
                if chunkNumber >= self.totalChunks {
                    self.isPlaying = false
                    self.onAllChunksFinished?()
                }
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
            isPlaying = true
        }
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
    }
}
