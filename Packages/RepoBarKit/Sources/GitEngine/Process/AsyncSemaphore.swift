import Foundation

/// Counting semaphore for structured concurrency. Cancellation-safe: a cancelled waiter is removed
/// and never receives a permit.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(_ permits: Int) {
        self.permits = max(1, permits)
    }

    public func acquire() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            permits += 1
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Runs `body` while holding one permit. The body runs in the caller's context.
    public nonisolated func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
