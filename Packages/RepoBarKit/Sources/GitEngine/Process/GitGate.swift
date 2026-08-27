import Foundation

/// Limits concurrent git work globally and serializes work per shared `.git` directory
/// (linked worktrees share `refs/remotes/*`; concurrent fetches would hit "cannot lock ref").
public actor GitGate {
    private let global: AsyncSemaphore
    private var perCommonDir: [String: AsyncSemaphore] = [:]

    public init(maxConcurrent: Int) {
        global = AsyncSemaphore(maxConcurrent)
    }

    private func semaphore(for commonDir: String) -> AsyncSemaphore {
        if let existing = perCommonDir[commonDir] { return existing }
        let created = AsyncSemaphore(1)
        perCommonDir[commonDir] = created
        return created
    }

    public func withSlot<T: Sendable>(commonDir: String, _ body: @Sendable () async throws -> T) async throws -> T {
        // Local first: taking the global permit before queueing on the per-repository one
        // meant a worktree's siblings sat on global slots they were not yet using, starving
        // unrelated repositories. This is the only ordering, so it cannot deadlock.
        let local = semaphore(for: commonDir)
        return try await local.withPermit {
            try await global.withPermit(body)
        }
    }
}
