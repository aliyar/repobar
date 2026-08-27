import Foundation
import os

// MARK: - Public API

/// Everything needed to launch one subprocess.
public struct ProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    /// Complete environment for the child. `Process` replaces the environment; it does not merge.
    public var environment: [String: String]
    public var timeout: Duration
    /// Time between SIGTERM and SIGKILL when a timeout or cancellation kills the process.
    public var killGracePeriod: Duration
    /// Per-stream capture limit; output beyond it is discarded (the process keeps running).
    public var outputLimit: Int
    public var qualityOfService: QualityOfService

    public init(
        executable: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(60),
        killGracePeriod: Duration = .seconds(3),
        outputLimit: Int = 8 * 1024 * 1024,
        qualityOfService: QualityOfService = .utility
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.killGracePeriod = killGracePeriod
        self.outputLimit = outputLimit
        self.qualityOfService = qualityOfService
    }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var terminationReason: Process.TerminationReason
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var duration: Duration

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// Exit 0 via normal termination and no timeout.
    public var succeeded: Bool { exitCode == 0 && terminationReason == .exit && !timedOut }

    public init(exitCode: Int32, terminationReason: Process.TerminationReason, stdout: Data, stderr: Data, timedOut: Bool, duration: Duration) {
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.duration = duration
    }
}

public enum ProcessLaunchError: Error, Sendable, Equatable {
    case executableNotFound(URL)
    case workingDirectoryMissing(URL)
    case launchFailed(String)
}

/// Abstraction over subprocess execution so tests can record or stub invocations.
public protocol ProcessRunning: Sendable {
    /// Throws `ProcessLaunchError` when the process cannot be started and `CancellationError`
    /// when the calling task is cancelled (the child is killed first).
    func run(_ spec: ProcessSpec) async throws -> ProcessResult
}

// MARK: - Foundation implementation

/// `Foundation.Process` based runner.
///
/// Invariants:
/// - stdin is `/dev/null`, so nothing can ever block waiting for a terminal prompt;
/// - both pipes are drained concurrently from launch (no 64 KB pipe-buffer deadlock);
/// - the termination handler → continuation bridge resumes exactly once, in either order;
/// - timeout escalates SIGTERM → SIGKILL; task cancellation does the same;
/// - after exit, EOF on the pipes is awaited with a bound, because grandchildren (ssh, git-remote-https)
///   can briefly outlive git while holding the pipe's write end.
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: spec.executable.path) else {
            throw ProcessLaunchError.executableNotFound(spec.executable)
        }
        if let workingDirectory = spec.workingDirectory {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProcessLaunchError.workingDirectoryMissing(workingDirectory)
            }
        }

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        process.environment = spec.environment
        process.qualityOfService = spec.qualityOfService
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let control = ProcessControl(process)
        let exitSignal = ExitSignal()
        let stdout = PipeCollector(stdoutPipe.fileHandleForReading, limit: spec.outputLimit)
        let stderr = PipeCollector(stderrPipe.fileHandleForReading, limit: spec.outputLimit)
        let clock = ContinuousClock()
        let started = clock.now

        // Installed before launch so it can never fire before we are ready. Runs on an arbitrary thread.
        process.terminationHandler = { finished in
            exitSignal.fire(status: finished.terminationStatus, reason: finished.terminationReason)
        }

        do {
            try control.launch()
        } catch is CancellationError {
            stdout.abandon(); stderr.abandon()
            throw CancellationError()
        } catch {
            stdout.abandon(); stderr.abandon()
            throw ProcessLaunchError.launchFailed(error.localizedDescription)
        }

        let timeout = spec.timeout
        let grace = spec.killGracePeriod
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            control.markTimedOut()
            control.terminate()
            try await Task.sleep(for: grace)
            control.kill()
        }
        defer { watchdog.cancel() }

        let (status, reason) = await withTaskCancellationHandler {
            await exitSignal.wait()
        } onCancel: {
            control.terminate()
            let deadline = DispatchTime.now() + .milliseconds(Int(max(0, grace.components.seconds * 1000 + grace.components.attoseconds / 1_000_000_000_000_000)))
            DispatchQueue.global().asyncAfter(deadline: deadline) { control.kill() }
        }
        // Cancelled here, not by the defer at function exit: the process has finished, so the
        // drain below must not be able to mark a successful run as timed out.
        watchdog.cancel()

        await withBoundedWait(.seconds(2)) {
            await stdout.waitForEOF()
            await stderr.waitForEOF()
        }

        try Task.checkCancellation()
        return ProcessResult(
            exitCode: status,
            terminationReason: reason,
            stdout: stdout.data,
            stderr: stderr.data,
            timedOut: control.timedOut,
            duration: clock.now - started
        )
    }
}

/// Runs `operation`, giving up (and cancelling it) after `duration`.
func withBoundedWait(_ duration: Duration, _ operation: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask { try? await Task.sleep(for: duration) }
        await group.next()
        group.cancelAll()
    }
}

// MARK: - Support types

/// Serializes launch/terminate/kill and guards the ObjC preconditions
/// ("terminate() requires a launched task", "cannot launch twice").
final class ProcessControl: Sendable {
    private struct State {
        var launched = false
        var cancelRequested = false
        var timedOut = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func launch() throws {
        try state.withLock { state in
            if state.cancelRequested { throw CancellationError() }
            try process.run()
            state.launched = true
        }
    }

    /// SIGTERM — git removes its `*.lock` files on SIGTERM, so prefer this over SIGKILL.
    func terminate() {
        state.withLock { state in
            state.cancelRequested = true
            guard state.launched, process.isRunning else { return }
            process.terminate()
        }
    }

    func kill() {
        state.withLock { state in
            guard state.launched, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func markTimedOut() {
        state.withLock { $0.timedOut = true }
    }

    var timedOut: Bool {
        state.withLock { $0.timedOut }
    }
}

/// Exactly-once, order-independent bridge between `terminationHandler` and the awaiting task.
final class ExitSignal: Sendable {
    typealias Value = (Int32, Process.TerminationReason)

    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire(status: Int32, reason: Process.TerminationReason) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = (status, reason)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: (status, reason))
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Value? in
                if let value = state.value { return value }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Non-blocking, GCD-driven pipe reader. No cooperative-pool thread is ever blocked; a straggling
/// grandchild holding the write end only delays EOF, never a thread.
final class PipeCollector: Sendable {
    private struct State {
        var data = Data()
        var eof = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handle: FileHandle

    init(_ handle: FileHandle, limit: Int) {
        self.handle = handle
        let state = self.state
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if chunk.isEmpty {
                    state.eof = true
                    defer { state.waiter = nil }
                    return state.waiter
                }
                if state.data.count < limit {
                    state.data.append(chunk.prefix(limit - state.data.count))
                }
                return nil
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil // otherwise the handler spins at EOF
                try? handle.close()
                waiter?.resume()
            }
        }
    }

    /// Stops reading without waiting (used when the launch itself failed).
    func abandon() {
        handle.readabilityHandler = nil
        try? handle.close()
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.eof = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func waitForEOF() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Checked inside: on an already-cancelled task the onCancel handler below has
                // run before we stored the continuation, so parking here would wait for a real
                // EOF that a grandchild holding the pipe may never deliver.
                let done = state.withLock { state -> Bool in
                    if state.eof || Task.isCancelled { return true }
                    state.waiter = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }

    var data: Data {
        state.withLock { $0.data }
    }
}
