import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// A word-level timing, extracted from KokoroSwift's `MToken` (a class,
/// not Sendable) into a plain Sendable value so it can cross the
/// `KokoroEngine` actor boundary.
struct SpokenWord: Sendable, Identifiable {
    let id = UUID()
    let text: String
    let trailingWhitespace: String
    /// Seconds from the start of this chunk's audio. `nil` when Kokoro's
    /// timestamp predictor couldn't align this token (rare, e.g. very
    /// short chunks) — such words just never highlight.
    let startTime: Double?
    let endTime: Double?
}

actor KokoroEngine {
    static let shared = KokoroEngine()

    static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    private var tts: KokoroTTS?
    private var voiceEmbeddings: [String: MLXArray] = [:]

    var isLoaded: Bool { tts != nil }

    enum EngineError: LocalizedError {
        case voicesLoadFailed
        case voiceNotFound(String)

        var errorDescription: String? {
            switch self {
            case .voicesLoadFailed:
                "Couldn't read the bundled voice styles file."
            case .voiceNotFound(let name):
                "Voice \"\(name)\" isn't available."
            }
        }
    }

    func load(modelURL: URL, voicesURL: URL) throws {
        guard tts == nil else { return }
        let loadedTTS = KokoroTTS(modelPath: modelURL)
        guard let embeddings = NpyzReader.read(fileFromPath: voicesURL), !embeddings.isEmpty else {
            throw EngineError.voicesLoadFailed
        }
        tts = loadedTTS
        voiceEmbeddings = embeddings
    }

    func synthesize(text: String, voice: String, speed: Float) throws -> (samples: [Float], words: [SpokenWord]) {
        guard let tts else { throw EngineError.voicesLoadFailed }
        guard let embedding = voiceEmbeddings[voice + ".npy"] else {
            throw EngineError.voiceNotFound(voice)
        }
        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB
        let (samples, tokens) = try tts.generateAudio(voice: embedding, language: language, text: text, speed: speed)
        let words = (tokens ?? []).map {
            SpokenWord(text: $0.text, trailingWhitespace: $0.whitespace, startTime: $0.start_ts, endTime: $0.end_ts)
        }
        return (samples, words)
    }
}
