import Foundation
import os
@testable import GitEngine

/// Wraps the real runner and records every invocation's arguments.
final class RecordingProcessRunner: ProcessRunning, Sendable {
    private let inner = FoundationProcessRunner()
    private let recorded = OSAllocatedUnfairLock(initialState: [[String]]())
    private let held = OSAllocatedUnfairLock(initialState: Hold())

    private struct Hold {
        var subcommand: String?
        var duration: Duration = .zero
    }

    /// Slows one git subcommand down so a test can act while a check is genuinely in flight —
    /// the only way to reach the engine's "while a check is running" paths from outside.
    func hold(_ subcommand: String, for duration: Duration) {
        held.withLock { $0 = Hold(subcommand: subcommand, duration: duration) }
    }

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        recorded.withLock { $0.append(spec.arguments) }
        let hold = held.withLock { $0 }
        if let subcommand = hold.subcommand, spec.arguments.contains(subcommand) {
            try? await Task.sleep(for: hold.duration)
        }
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
