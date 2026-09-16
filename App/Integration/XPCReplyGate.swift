import Foundation

/// Owns a single XPC continuation and ignores callbacks after the first terminal event.
final class XPCReplyGate: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning data: Data) -> Bool {
        resume(.success(data))
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Data, Error>) -> Bool {
        let shouldResume = lock.withLock {
            guard didResume == false else { return false }
            didResume = true
            return true
        }
        guard shouldResume else { return false }
        continuation.resume(with: result)
        return true
    }
}
