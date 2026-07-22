import Foundation

/// Owns a single XPC continuation and ignores callbacks after the first terminal event.
final class XPCReplyGate: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        resume(.success(data))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Data, Error>) {
        let shouldResume = lock.withLock {
            guard didResume == false else { return false }
            didResume = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}
