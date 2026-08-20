import Foundation
import Testing
@testable import GitEngine

@Suite("GitErrorClassifier")
struct GitErrorClassifierTests {
    @Test(arguments: [
        ("fatal: not a git repository (or any of the parent directories): .git", RepoError.notARepository),
        ("fatal: cannot change to '/Volumes/x/repo': No such file or directory", .repoMissing),
        ("fatal: detected dubious ownership in repository at '/tmp/x'", .dubiousOwnership),
        ("fatal: Unable to create '/x/.git/index.lock': File exists.", .lockConflict),
        ("error: cannot lock ref 'refs/remotes/origin/main'", .lockConflict),
        ("Host key verification failed.\nfatal: Could not read from remote repository.", .hostKeyVerification),
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .authFailed(.ssh)),
        ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", .authFailed(.https)),
        ("remote: Invalid username or token. Password authentication is not supported", .authFailed(.https)),
        ("fatal: Authentication failed for 'https://gitlab.com/x/y.git/'", .authFailed(.https)),
        ("ERROR: Repository not found.\nfatal: Could not read from remote repository.", .repositoryNotFound),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/x/y.git/' not found", .repositoryNotFound),
        ("fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.", .noRemote),
        ("error: No such remote 'origin'", .noRemote),
        ("fatal: couldn't find remote ref refs/heads/nope", .remoteRefNotFound(branch: nil)),
        ("fatal: unable to access 'https://x/': SSL certificate problem: unable to get local issuer certificate", .tlsError),
        ("fatal: unable to access 'https://x/': Could not resolve host: nonexistent.invalid", .networkUnreachable),
        ("ssh: connect to host 127.0.0.1 port 1: Connection refused", .networkUnreachable),
        ("fatal: unable to access 'https://x/': Failed to connect to 127.0.0.1 port 1 after 0 ms: Couldn't connect to server", .networkUnreachable),
        ("kex_exchange_identification: Connection closed by remote host", .networkUnreachable),
        ("error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502", .serverError),
        ("fatal: Invalid symmetric difference expression abc...def", .badRevision),
        ("fatal: bad revision 'deadbeef'", .badRevision),
        ("fatal: Not possible to fast-forward, aborting.", .ffNotPossible),
        ("error: Your local changes to the following files would be overwritten by merge:\n\tREADME.md", .localChangesWouldBeOverwritten),
        ("error: You have not concluded your merge (MERGE_HEAD exists).", .operationInProgress),
    ])
    func classifies(stderr: String, expected: RepoError) {
        #expect(GitErrorClassifier.classify(stderr: stderr) == expected)
    }

    @Test func unknownUsesFirstMeaningfulLineWithoutPrefix() {
        let error = GitErrorClassifier.classify(stderr: "\n  fatal: something completely new happened\nsecond line")
        #expect(error == .unknown("something completely new happened"))
        #expect(GitErrorClassifier.classify(stderr: "") == .unknown("git failed"))
    }

    @Test func precedenceAuthBeforeConnectionClosed() {
        let stderr = "git@github.com: Permission denied (publickey).\nConnection closed by 140.82.121.4 port 22"
        #expect(GitErrorClassifier.classify(stderr: stderr) == .authFailed(.ssh))
    }

    @Test func failureKinds() {
        #expect(RepoError.authFailed(.ssh).failureKind == .auth)
        #expect(RepoError.networkUnreachable.failureKind == .network)
        #expect(RepoError.lockConflict.failureKind == .lock)
        #expect(RepoError.notARepository.failureKind == .fatal)
        #expect(RepoError.ffNotPossible.failureKind == .user)
    }
}

@Suite("RemoteURL")
struct RemoteURLTests {
    @Test(arguments: [
        ("git@github.com:owner/repo.git", "github.com", "owner/repo"),
        ("git@github.com:owner/repo", "github.com", "owner/repo"),
        ("ssh://git@github.com/owner/repo.git", "github.com", "owner/repo"),
        ("ssh://git@host.example.com:2222/owner/repo.git", "host.example.com", "owner/repo"),
        ("https://host/owner/repo.git", "host", "owner/repo"),
        ("https://user@gitlab.com/group/sub/repo.git", "gitlab.com", "group/sub/repo"),
        ("https://github.com/owner/repo/", "github.com", "owner/repo"),
        ("git@bitbucket.org:o/r.git", "bitbucket.org", "o/r"),
        ("git@ssh.dev.azure.com:v3/org/proj/repo", "dev.azure.com", "org/proj/_git/repo"),
        ("git@ssh.github.com:owner/repo.git", "github.com", "owner/repo"),
        ("git@work:o/r.git", "work", "o/r"),
        ("GIT@GitHub.com:Owner/Repo.GIT", "github.com", "Owner/Repo"),
    ])
    func parses(raw: String, host: String, path: String) {
        let parsed = RemoteURL.parse(raw)
        #expect(parsed?.host == host)
        #expect(parsed?.path == path)
    }

    @Test func localAndFileHaveNoWebURL() {
        #expect(RemoteURL.parse("/Users/x/repo.git")?.scheme == .local)
        #expect(RemoteURL.parse("../repo")?.scheme == .local)
        #expect(RemoteURL.parse("file:///Users/x/repo.git")?.scheme == .file)
        #expect(WebRemote.from(remote: "file:///Users/x/repo.git") == nil)
        #expect(WebRemote.from(remote: "/Users/x/repo") == nil)
        #expect(RemoteURL.parse("") == nil)
    }

    @Test func webURLs() throws {
        let github = try #require(WebRemote.from(remote: "git@github.com:owner/repo.git"))
        #expect(github.kind == .github)
        #expect(github.repoURL.absoluteString == "https://github.com/owner/repo")
        #expect(github.commitURL("abc").absoluteString == "https://github.com/owner/repo/commit/abc")
        #expect(github.compareURL(from: "a", to: "b")?.absoluteString == "https://github.com/owner/repo/compare/a...b")

        let gitlab = try #require(WebRemote.from(remote: "https://gitlab.com/group/sub/repo.git"))
        #expect(gitlab.kind == .gitlab)
        #expect(gitlab.commitURL("abc").absoluteString == "https://gitlab.com/group/sub/repo/-/commit/abc")

        let bitbucket = try #require(WebRemote.from(remote: "git@bitbucket.org:o/r.git"))
        #expect(bitbucket.commitURL("abc").absoluteString == "https://bitbucket.org/o/r/commits/abc")
        #expect(bitbucket.compareURL(from: "a", to: "b") == nil)

        let azure = try #require(WebRemote.from(remote: "git@ssh.dev.azure.com:v3/org/proj/repo"))
        #expect(azure.kind == .azureDevOps)
        #expect(azure.repoURL.absoluteString == "https://dev.azure.com/org/proj/_git/repo")

        let unknown = try #require(WebRemote.from(remote: "git@work:o/r.git"))
        #expect(unknown.kind == .unknown)
        #expect(unknown.commitURL("abc").absoluteString == "https://work/o/r/commit/abc")

        let http = try #require(WebRemote.from(remote: "http://gitea.local:3000/o/r.git"))
        #expect(http.kind == .gitea)
        #expect(http.repoURL.absoluteString == "http://gitea.local/o/r")
    }

    @Test func overrideWins() throws {
        let web = try #require(WebRemote.from(remote: "git@work:o/r.git", override: "https://github.example.com/o/r"))
        #expect(web.kind == .github)
        #expect(web.commitURL("abc").absoluteString == "https://github.example.com/o/r/commit/abc")
    }
}

@Suite("GitEnvironment")
struct GitEnvironmentTests {
    @Test func buildsSafeEnvironment() {
        let base = [
            "HOME": "/Users/x", "USER": "x", "SSH_AUTH_SOCK": "/tmp/agent.sock", "PATH": "/usr/bin:/bin",
            "GIT_ASKPASS": "/usr/bin/askpass", "GIT_DIR": "/somewhere/.git", "DISPLAY": ":0",
        ]
        let env = GitEnvironment.make(base: base, gitExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/git"), extraPaths: ["/nonexistent/dir"], sshBatchMode: true)
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(env["LC_ALL"] == "C")
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(env["HOME"] == "/Users/x")
        #expect(env["GIT_ASKPASS"] == nil)
        #expect(env["GIT_DIR"] == nil)
        #expect(env["DISPLAY"] == nil)
        #expect(env["GIT_SSH_COMMAND"] == GitEnvironment.sshBatchCommand)
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("/usr/bin"))
        #expect(!path.contains("/nonexistent/dir"))
        #expect(Set(path).count == path.count, "PATH entries are unique")
    }

    @Test func respectsUserSSHCommand() {
        let env = GitEnvironment.make(base: ["GIT_SSH_COMMAND": "ssh -v"], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), sshBatchMode: true)
        #expect(env["GIT_SSH_COMMAND"] == "ssh -v")
        let env2 = GitEnvironment.make(base: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), sshBatchMode: false)
        #expect(env2["GIT_SSH_COMMAND"] == nil)
    }
}

@Suite("GitLocator")
struct GitLocatorTests {
    @Test func parsesVersions() {
        let url = URL(fileURLWithPath: "/usr/bin/git")
        let apple = GitInstallation.parseVersion("git version 2.50.1 (Apple Git-155)\n", url: url)
        #expect(apple?.major == 2)
        #expect(apple?.minor == 50)
        #expect(apple?.patch == 1)
        #expect(apple?.supportsFetchPorcelain == true)
        let old = GitInstallation.parseVersion("git version 2.39.5", url: url)
        #expect(old?.supportsFetchPorcelain == false)
        #expect(old?.isSupported == true)
        #expect(GitInstallation.parseVersion("nonsense", url: url) == nil)
    }

    @Test func locatesFakeGitScriptFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("git")
        try "#!/bin/sh\necho 'git version 2.99.0 (fake)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let locator = GitLocator(extraCandidates: [fake])
        let installation = try #require(await locator.locate(override: nil))
        #expect(installation.url == fake)
        #expect(installation.minor == 99)
    }

    @Test func skipsUnsupportedOrBrokenCandidates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("git")
        try "#!/bin/sh\necho 'git version 1.8.0'\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)

        let locator = GitLocator(extraCandidates: [broken])
        let installation = await locator.locate(override: nil)
        // Falls through to a real git on this machine (Homebrew/CLT), which is ≥ 2.29.
        #expect(installation?.url != broken)
        #expect(installation?.isSupported == true)
    }
}
