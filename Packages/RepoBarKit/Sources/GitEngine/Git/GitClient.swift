import Foundation
import os

/// Result of one git invocation (non-zero exit codes are returned, not thrown, by `output(_:)`).
public struct GitOutput: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: String
    public var timedOut: Bool
    public var duration: Duration

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum GitError: Error, Sendable {
    case gitNotFound
    case launchFailed(ProcessLaunchError)
    case timedOut(arguments: [String], after: Duration)
    case failed(exitCode: Int32, stderr: String, arguments: [String])

    /// Maps to the user-facing classification.
    public var repoError: RepoError {
        switch self {
        case .gitNotFound: .gitNotFound
        case .launchFailed(.executableNotFound): .gitNotFound
        case .launchFailed(.workingDirectoryMissing): .repoMissing
        case .launchFailed(.launchFailed(let message)): .unknown(message)
        case .timedOut(_, let after): .timeout(seconds: Int(after.seconds))
        case .failed(_, let stderr, _): GitErrorClassifier.classify(stderr: stderr)
        }
    }
}

/// Thin, stateless wrapper that runs git with the right environment and timeouts.
public struct GitClient: Sendable {
    public var installation: GitInstallation
    public var runner: any ProcessRunning
    /// Environment for local (non-network) commands.
    public var environment: [String: String]
    /// Environment for network commands (may add `GIT_SSH_COMMAND`).
    public var networkEnvironment: [String: String]
    public var logger = Logger(subsystem: "com.aliyar.RepoBar", category: "git")
    /// Default timeout for local commands (tests shrink it).
    public var defaultTimeout: Duration = GitClient.localTimeout

    public static let localTimeout: Duration = .seconds(20)
    public static let probeTimeout: Duration = .seconds(30)
    public static let fetchTimeout: Duration = .seconds(90)
    public static let mergeTimeout: Duration = .seconds(60)

    public init(installation: GitInstallation, runner: any ProcessRunning = FoundationProcessRunner(), environment: [String: String], networkEnvironment: [String: String]? = nil) {
        self.installation = installation
        self.runner = runner
        self.environment = environment
        self.networkEnvironment = networkEnvironment ?? environment
    }

    /// Runs git; non-zero exit is returned in `GitOutput`. Throws only for launch failures and timeouts.
    public func output(_ arguments: [String], in repo: URL?, timeout: Duration? = nil, network: Bool = false) async throws -> GitOutput {
        let timeout = timeout ?? defaultTimeout
        var args = ["--no-optional-locks", "-c", "color.ui=never"]
        if let repo { args += ["-C", repo.path] }
        args += arguments
        let spec = ProcessSpec(
            executable: installation.url,
            arguments: args,
            workingDirectory: nil,
            environment: network ? networkEnvironment : environment,
            timeout: timeout
        )
        let result: ProcessResult
        do {
            result = try await runner.run(spec)
        } catch let error as ProcessLaunchError {
            throw GitError.launchFailed(error)
        }
        let output = GitOutput(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderrText, timedOut: result.timedOut, duration: result.duration)
        logger.debug("git \(arguments.joined(separator: " "), privacy: .public) → \(result.exitCode) in \(result.duration.formattedMilliseconds, privacy: .public)")
        if result.timedOut { throw GitError.timedOut(arguments: arguments, after: timeout) }
        return output
    }

    /// Runs git and throws `GitError.failed` on non-zero exit.
    @discardableResult
    public func run(_ arguments: [String], in repo: URL?, timeout: Duration? = nil, network: Bool = false) async throws -> GitOutput {
        let output = try await output(arguments, in: repo, timeout: timeout, network: network)
        guard output.exitCode == 0 else {
            throw GitError.failed(exitCode: output.exitCode, stderr: output.stderr, arguments: arguments)
        }
        return output
    }
}

extension Duration {
    var formattedMilliseconds: String {
        let ms = seconds * 1000
        return String(format: "%.0f ms", ms)
    }
}
