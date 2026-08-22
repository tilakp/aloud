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

    func isInstalledOnDisk() -> Bool {
        fileManager.fileExists(atPath: modelFileURL.path) && fileManager.fileExists(atPath: voicesFileURL.path)
    }

    func ensureInstalled() async {
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
        let data = try Data(contentsOf: tempURL)
        let digestHex = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
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
