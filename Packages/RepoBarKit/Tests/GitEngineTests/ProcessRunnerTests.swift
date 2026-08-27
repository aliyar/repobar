import Foundation
import Testing
@testable import GitEngine

@Suite("ProcessRunner", .timeLimit(.minutes(1)))
struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()
    let sh = URL(fileURLWithPath: "/bin/sh")

    func spec(_ script: String, timeout: Duration = .seconds(20), limit: Int = 8 * 1024 * 1024) -> ProcessSpec {
        ProcessSpec(executable: sh, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, outputLimit: limit)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let result = try await runner.run(spec("echo out; echo err 1>&2; exit 3"))
        #expect(result.exitCode == 3)
        #expect(result.terminationReason == .exit)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
        #expect(result.timedOut == false)
        #expect(result.succeeded == false)
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let result = try await runner.run(spec("head -c 5242880 /dev/zero; head -c 5242880 /dev/zero 1>&2"))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 5_242_880)
        #expect(result.stderr.count == 5_242_880)
    }

    @Test func outputLimitTruncates() async throws {
        let result = try await runner.run(spec("head -c 3000000 /dev/zero", limit: 1_000_000))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1_000_000)
    }

    @Test func timeoutEscalatesToKill() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var s = spec("sleep 30", timeout: .milliseconds(300))
        s.killGracePeriod = .milliseconds(300)
        let result = try await runner.run(s)
        let elapsed = clock.now - start
        #expect(result.timedOut)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.exitCode == SIGTERM || result.exitCode == SIGKILL)
        #expect(elapsed < .seconds(4), "took \(elapsed)")
    }

    @Test func cancellationKillsProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let runner = self.runner
        let spec = self.spec("sleep 30")
        let task = Task { try await runner.run(spec) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationBeforeLaunchThrowsWithoutRunning() async throws {
        let runner = self.runner
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-\(UUID().uuidString)")
        let spec = self.spec("touch '\(marker.path)'")
        let task = Task {
            try await Task.sleep(for: .seconds(5)) // give cancel() time to land before run() starts
            return try await runner.run(spec)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test func missingExecutableThrows() async {
        let bogus = URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)")
        await #expect(throws: ProcessLaunchError.executableNotFound(bogus)) {
            _ = try await runner.run(ProcessSpec(executable: bogus))
        }
    }

    @Test func missingWorkingDirectoryThrows() async {
        let dir = URL(fileURLWithPath: "/nonexistent/dir-\(UUID().uuidString)")
        await #expect(throws: ProcessLaunchError.workingDirectoryMissing(dir)) {
            _ = try await runner.run(ProcessSpec(executable: sh, arguments: ["-c", "true"], workingDirectory: dir))
        }
    }

    @Test func stdinIsNullDevice() async throws {
        let result = try await runner.run(ProcessSpec(executable: URL(fileURLWithPath: "/bin/cat"), timeout: .seconds(5)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func grandchildHoldingPipeDoesNotBlockBeyondBoundedDrain() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(spec("(sleep 3 1>&2 &); echo done"))
        let elapsed = clock.now - start
        #expect(result.stdoutText == "done\n")
        #expect(result.exitCode == 0)
        #expect(elapsed < .milliseconds(2900), "took \(elapsed)")
    }

    /// The watchdog used to be cancelled only at function exit — after the drain — so a fetch
    /// that finished at 89.9 s of a 90 s timeout was still reported as timed out, turning a
    /// successful update into an error plus network backoff.
    @Test func aProcessThatFinishesInTimeIsNotReportedAsTimedOut() async throws {
        let result = try await runner.run(spec("echo done; (sleep 3 1>&2 &)", timeout: .seconds(1)))
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "done\n")
        #expect(!result.timedOut, "it exited immediately; only the drain crossed the deadline")
    }

    /// Both pipes held by a grandchild: waitForEOF parked past the 2 s bound because it stored
    /// its continuation without noticing the task was already cancelled.
    @Test func grandchildHoldingBothPipesStillRespectsTheDrainBound() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(spec("(sleep 6 &); echo done"))
        let elapsed = clock.now - start
        #expect(result.exitCode == 0)
        #expect(elapsed < .milliseconds(3500), "took \(elapsed)")
    }

    @Test func workingDirectoryAndEnvironmentAreApplied() async throws {
        let dir = FileManager.default.temporaryDirectory
        var s = spec("pwd; printf %s \"$REPOBAR_TEST\"")
        s.workingDirectory = dir
        s.environment["REPOBAR_TEST"] = "yes"
        let result = try await runner.run(s)
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(URL(fileURLWithPath: lines[0]).standardizedFileURL.resolvingSymlinksInPath() == dir.standardizedFileURL.resolvingSymlinksInPath())
        #expect(lines[1] == "yes")
    }
}
