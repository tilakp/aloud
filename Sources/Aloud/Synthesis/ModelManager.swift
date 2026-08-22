import Foundation
import CryptoKit

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum State: Equatable {
        case notInstalled
        case downloading(label: String, bytesWritten: Int64, totalBytes: Int64)
        case verifying(label: String)
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    private let fileManager = FileManager.default
    private var isEnsuring = false

    private lazy var modelsDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Aloud/Models", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var modelFileURL: URL { modelsDirectory.appendingPathComponent(ModelAsset.modelFileName) }
    var voicesFileURL: URL { modelsDirectory.appendingPathComponent(ModelAsset.voicesFileName) }

    private init() {
        if isInstalledOnDisk() {
            state = .installed
        }
    }

    /// Checks existence *and* expected file size — cheap enough to run on
    /// every launch, and catches a truncated/corrupted file that a plain
    /// existence check would trust forever (the SHA-256 check only ever
    /// runs once, at initial download time).
    func isInstalledOnDisk() -> Bool {
        fileSize(at: modelFileURL) == ModelAsset.modelSize && fileSize(at: voicesFileURL) == ModelAsset.voicesSize
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    func ensureInstalled() async {
        guard !isEnsuring else { return }
        isEnsuring = true
        defer { isEnsuring = false }

        if isInstalledOnDisk() {
            state = .installed
            return
        }
        do {
            try await downloadAsset(
                url: ModelAsset.modelURL,
                destination: modelFileURL,
                sha256: ModelAsset.modelSHA256,
                totalBytes: ModelAsset.modelSize,
                label: "Voice model"
            )
            try await downloadAsset(
                url: ModelAsset.voicesURL,
                destination: voicesFileURL,
                sha256: ModelAsset.voicesSHA256,
                totalBytes: ModelAsset.voicesSize,
                label: "Voice styles"
            )
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func downloadAsset(
        url: URL,
        destination: URL,
        sha256 expectedSHA256: String,
        totalBytes: Int64,
        label: String
    ) async throws {
        state = .downloading(label: label, bytesWritten: 0, totalBytes: totalBytes)

        let downloader = FileDownloader { [weak self] written, total in
            Task { @MainActor in
                self?.state = .downloading(label: label, bytesWritten: written, totalBytes: total > 0 ? total : totalBytes)
            }
        }
        let tempURL = try await downloader.download(from: url)

        state = .verifying(label: label)
        // Reading ~327MB and hashing it is real work — do it off the main
        // actor so the "Verifying…" spinner (and the rest of the UI) stays
        // responsive instead of freezing for the duration.
        let digestHex = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: tempURL)
            return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        }.value
        guard digestHex == expectedSHA256 else {
            try? fileManager.removeItem(at: tempURL)
            throw ModelError.checksumMismatch
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    enum ModelError: LocalizedError {
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                "The downloaded file didn't match the expected checksum. Try again."
            }
        }
    }
}
