import AVFoundation
import Foundation

/// Temporary diagnostic: writes the most recently synthesized chunk to disk
/// and logs its peak/RMS level, so audio content can be verified without
/// relying on someone listening for it. Remove once the pipeline is
/// confirmed producing real audio end-to-end.
enum DebugAudioDump {
    static func write(samples: [Float], sampleRate: Double) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug-last-chunk.wav")

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            NSLog("[Aloud][debug] failed to build buffer for dump")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            NSLog("[Aloud][debug] failed to write wav: \(error.localizedDescription)")
        }

        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (samples.isEmpty ? 0 : sqrt(sumSquares / Float(samples.count)))
        let duration = Double(samples.count) / sampleRate
        NSLog("[Aloud][debug] chunk: \(samples.count) samples, \(String(format: "%.2f", duration))s, peak=\(peak), rms=\(rms) -> \(url.path)")
    }
}
