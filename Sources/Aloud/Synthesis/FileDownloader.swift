import Foundation

/// Thin async wrapper around URLSessionDownloadTask that reports byte-level
/// progress, since URLSession's async `bytes(from:)`/`download(for:)` APIs
/// don't expose progress without a delegate.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progressHandler: (Int64, Int64) -> Void
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(progressHandler: @escaping (Int64, Int64) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted the moment this method returns, so move it
        // to a stable temp file before resuming the continuation.
        let stableURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            continuation?.resume(returning: stableURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
