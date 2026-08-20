import Foundation
import Testing
@testable import GitEngine

/// Builds throwaway repositories with an isolated git configuration (no access to the developer's
/// ~/.gitconfig, keychain, or ssh agent). Each fixture lives in its own temp directory.
final class GitFixture: Sendable {
    let root: URL
    let home: URL
    let environment: [String: String]
    let installation: GitInstallation
    let runner: RecordingProcessRunner
    let git: GitClient

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = """
        [user]
            name = Test
            email = test@example.com
        [init]
            defaultBranch = main
        [commit]
            gpgsign = false
        [protocol "file"]
            allow = always
        [advice]
            detachedHead = false
        """
        try config.write(to: home.appendingPathComponent("gitconfig"), atomically: true, encoding: .utf8)

        let locator = GitLocator()
        guard let found = await locator.locate(override: ProcessInfo.processInfo.environment["REPOBAR_TEST_GIT"].map { URL(fileURLWithPath: $0) }) else {
            throw FixtureError.gitNotFound
        }
        installation = found

        var base: [String: String] = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "GIT_CONFIG_GLOBAL": home.appendingPathComponent("gitconfig").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
            "GIT_AUTHOR_DATE": "2024-01-01T00:00:00+0000", "GIT_COMMITTER_DATE": "2024-01-01T00:00:00+0000",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        base = GitEnvironment.make(base: base, gitExecutable: found.url, sshBatchMode: false)
        base["GIT_SSH_COMMAND"] = "/usr/bin/false" // any ssh use is a test bug
        environment = base
        runner = RecordingProcessRunner()
        git = GitClient(installation: found, runner: runner, environment: base, networkEnvironment: base)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    enum FixtureError: Error { case gitNotFound, commandFailed(String) }

    // MARK: Raw git helpers (used to *build* scenarios, not the code under test)

    @discardableResult
    func sh(_ arguments: [String], in directory: URL? = nil, env: [String: String] = [:]) async throws -> String {
        var environment = self.environment
        for (key, value) in env { environment[key] = value }
        var args = arguments
        if let directory { args = ["-C", directory.path] + args }
        let spec = ProcessSpec(executable: installation.url, arguments: args, environment: environment, timeout: .seconds(30))
        let result = try await FoundationProcessRunner().run(spec)
        guard result.exitCode == 0 else {
            throw FixtureError.commandFailed("git \(arguments.joined(separator: " ")): \(result.stderrText)")
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// Bare remote with one initial commit on `main` (so clones get origin/HEAD).
    func makeRemote(named name: String = "remote.git", seeded: Bool = true) async throws -> URL {
        let remote = directory(name)
        try await sh(["init", "--bare", "--initial-branch=main", remote.path])
        if seeded {
            let seed = directory("seed-\(UUID().uuidString.prefix(6))")
            try await sh(["clone", "-q", remote.path, seed.path])
            try await commit(in: seed, file: "README.md", content: "# seed\n", message: "Initial commit")
            try await sh(["push", "-q", "-u", "origin", "main"], in: seed)
            try? FileManager.default.removeItem(at: seed)
        }
        return remote
    }

    func clone(_ remote: URL, as name: String, extra: [String] = []) async throws -> URL {
        let dest = directory(name)
        try await sh(["clone", "-q"] + extra + [remote.path, dest.path])
        return dest
    }

    @discardableResult
    func commit(in repo: URL, file: String, content: String, message: String) async throws -> String {
        let url = repo.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try await sh(["add", "--", file], in: repo)
        try await sh(["commit", "-q", "-m", message], in: repo)
        return try await sh(["rev-parse", "HEAD"], in: repo)
    }

    func push(in repo: URL, _ refspec: String = "main", force: Bool = false) async throws {
        var args = ["push", "-q"]
        if force { args.append("--force") }
        args += ["origin", refspec]
        try await sh(args, in: repo)
    }

    func head(of repo: URL) async throws -> String {
        try await sh(["rev-parse", "HEAD"], in: repo)
    }

    // MARK: Engine helpers

    func record(for path: URL, watch: WatchMode = .upstreamOfCurrentBranch) async throws -> RepoRecord {
        let checker = RepoChecker(git: git)
        let validation = try await checker.validate(path: path)
        return RepoRecord(path: validation.toplevel, gitCommonDir: validation.gitCommonDir, watch: watch)
    }

    func check(_ record: RepoRecord, state: RepoState = RepoState(), options: CheckOptions = CheckOptions()) async -> CheckOutcome {
        await RepoChecker(git: git).check(record, state: state, options: options)
    }
}
