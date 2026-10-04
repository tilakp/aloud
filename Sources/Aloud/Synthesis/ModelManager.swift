import Foundation
import CryptoKit
import FluidAudio

/// The voice model ships inside the app (Resources/Model, fetched and
/// checksum-verified at build time by scripts/fetch-model.py). FluidAudio
/// only reads models from its cache, so at launch the files are cloned there
/// and checked before anything loads them. Nothing is ever downloaded.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum State: Equatable {
        case notInstalled
        /// Copying the bundled model into place, checking it and loading it.
        case preparing
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    private var isEnsuring = false

    private init() {
        // FluidAudio downloads any model file missing from its cache. Every
        // file is put there from the bundle first, so a download would mean
        // something is wrong: make it fail rather than quietly go online.
        ModelRegistry.baseURL = "https://offline.invalid"
    }

    func ensureInstalled() async {
        guard !isEnsuring, state != .installed else { return }
        isEnsuring = true
        defer { isEnsuring = false }

        do {
            state = .preparing
            let installStart = ContinuousClock.now
            try await Task.detached(priority: .userInitiated) {
                try Self.installBundledModel()
            }.value
            NSLog("[Aloud][perf] model install and checksum check took \(ContinuousClock.now - installStart)")
            try await KokoroEngine.shared.load()
            removeLegacyModelFiles()
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Makes every cache file match the bundled one: files that are missing
    /// or don't match their checksum are copied again from the bundle (a
    /// clone on APFS, so no extra disk space). Reads ~100MB to check them,
    /// so call it off the main actor.
    nonisolated private static func installBundledModel() throws {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Model"),
              let list = try? String(contentsOf: bundled.appendingPathComponent("files.tsv"), encoding: .utf8) else {
            throw ModelError.bundleMissing
        }
        let cache = try TtsCacheDirectory.ensure().appendingPathComponent("Models")
        let fileManager = FileManager.default

        for line in list.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2 else { continue }
            let expected = String(fields[0])
            let path = String(fields[1])
            let destination = cache.appendingPathComponent(path)
            if sha256(of: destination) == expected { continue }

            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundled.appendingPathComponent(path), to: destination)
            guard sha256(of: destination) == expected else {
                throw ModelError.checksumMismatch
            }
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum ModelError: LocalizedError {
        case bundleMissing
        case checksumMismatch

        var errorDescription: String? {
            "Aloud's built-in voice model is missing or damaged. Reinstall Aloud."
        }
    }

    /// Versions before the switch to FluidAudio downloaded ~340MB of MLX
    /// weights here. Nothing reads them any more.
    private func removeLegacyModelFiles() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Aloud/Models", isDirectory: true))
    }
}
