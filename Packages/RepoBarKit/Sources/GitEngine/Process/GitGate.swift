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
        let local = semaphore(for: commonDir)
        return try await global.withPermit {
            try await local.withPermit(body)
        }
    }
}
