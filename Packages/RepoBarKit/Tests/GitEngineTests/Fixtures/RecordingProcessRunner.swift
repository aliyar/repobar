import Foundation
import os
@testable import GitEngine

/// Wraps the real runner and records every invocation's arguments.
final class RecordingProcessRunner: ProcessRunning, Sendable {
    private let inner = FoundationProcessRunner()
    private let recorded = OSAllocatedUnfairLock(initialState: [[String]]())

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        recorded.withLock { $0.append(spec.arguments) }
        return try await inner.run(spec)
    }

    var invocations: [[String]] { recorded.withLock { $0 } }

    /// Git subcommands seen (first argument after the global `-C <path>` / `-c` options).
    var gitSubcommands: [String] {
        invocations.compactMap { args in
            var index = 0
            while index < args.count {
                switch args[index] {
                case "-C", "-c": index += 2
                case let option where option.hasPrefix("--"): index += 1
                default: return args[index]
                }
            }
            return nil
        }
    }

    func reset() { recorded.withLock { $0.removeAll() } }
}
