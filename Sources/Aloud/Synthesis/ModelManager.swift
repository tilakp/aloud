import Foundation
import FluidAudio

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum State: Equatable {
        case notInstalled
        case downloading(fraction: Double)
        /// Downloaded; loading the models and fetching the small
        /// pronunciation and voice files.
        case preparing
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    private var isEnsuring = false

    private init() {
        // Pins the CoreML model chain. The manifest check in ensureInstalled
        // covers the files FluidAudio still fetches from `main`.
        ModelRegistry.revisionOverrides = [ModelManifest.repo: ModelManifest.revision]
    }

    /// Safe to call on every launch: FluidAudio skips files already in its
    /// cache, so with everything present this only loads the models.
    func ensureInstalled() async {
        guard !isEnsuring, state != .installed else { return }
        isEnsuring = true
        defer { isEnsuring = false }

        do {
            state = .downloading(fraction: 0)
            try await KokoroAneResourceDownloader.ensureModels { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: progress.fractionCompleted)
                }
            }
            state = .preparing
            try await KokoroEngine.shared.load()
            let verifyStart = ContinuousClock.now
            let mismatched = try await Task.detached(priority: .utility) {
                try ModelManifest.mismatchedFiles()
            }.value
            NSLog("[Aloud][perf] model checksum check took \(ContinuousClock.now - verifyStart)")
            guard mismatched.isEmpty else {
                // Never synthesize with files nobody reviewed. Deleting them
                // lets Retry fetch them again.
                await KokoroEngine.shared.unload()
                NSLog("[Aloud] model files failed checksum: \(mismatched.map(\.lastPathComponent))")
                mismatched.forEach { try? FileManager.default.removeItem(at: $0) }
                throw ModelError.checksumMismatch
            }
            removeLegacyModelFiles()
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    enum ModelError: LocalizedError {
        case checksumMismatch

        var errorDescription: String? {
            "The downloaded voice files don't match the versions this build of Aloud expects. Try again, or update Aloud."
        }
    }

    /// Versions before the switch to FluidAudio downloaded ~340MB of MLX
    /// weights here. Nothing reads them any more.
    private func removeLegacyModelFiles() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Aloud/Models", isDirectory: true))
    }
}
