import Foundation
import FluidAudio

/// Kokoro-82M via FluidAudio's CoreML port, which keeps most of the model on
/// the Neural Engine. FluidAudio manages its own model files (downloaded
/// from Hugging Face into ~/.cache/fluidaudio).
actor KokoroEngine {
    static let shared = KokoroEngine()

    static let sampleRate = Double(KokoroAneConstants.sampleRate)

    private var manager: KokoroAneManager?
    /// Shared by concurrent callers (the launch preload and a hotkey read can
    /// both arrive while the first load is still awaiting), so the models
    /// are only loaded once.
    private var loadTask: Task<KokoroAneManager, Error>?

    var isLoaded: Bool { manager != nil }

    enum EngineError: LocalizedError {
        case notLoaded

        var errorDescription: String? { "The voice model isn't loaded." }
    }

    /// Downloads anything missing, then loads the models. Every voice is
    /// preloaded so that picking a different voice later works offline.
    func load() async throws {
        if manager != nil { return }
        let task = loadTask ?? Task {
            let manager = KokoroAneManager()
            try await manager.initialize(preloadVoices: Set(Voices.all.map(\.id)))
            return manager
        }
        loadTask = task
        do {
            manager = try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    func unload() {
        manager = nil
        loadTask = nil
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> [Float] {
        guard let manager else { throw EngineError.notLoaded }
        return try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed).samples
    }
}
