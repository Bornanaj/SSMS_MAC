import NIOConcurrencyHelpers

/// Serialises access to a resource across async callers, in FIFO order.
///
/// TDS has no multiplexing: a connection carries exactly one request at a time.
/// Swift actors are reentrant, so an `await` inside an actor method lets a second
/// call interleave — which is how two catalog queries end up racing for the same
/// socket. This lock closes that gap.
final class AsyncLock: @unchecked Sendable {
    private let lock = NIOLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired: Bool = lock.withLock {
                if isHeld {
                    waiters.append(continuation)
                    return false
                }
                isHeld = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isHeld = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
