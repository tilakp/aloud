import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

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

    func synthesize(text: String, voice: String, speed: Float) throws -> [Float] {
        guard let tts else { throw EngineError.voicesLoadFailed }
        guard let embedding = voiceEmbeddings[voice + ".npy"] else {
            throw EngineError.voiceNotFound(voice)
        }
        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB
        let (samples, _) = try tts.generateAudio(voice: embedding, language: language, text: text, speed: speed)
        return samples
    }
}
