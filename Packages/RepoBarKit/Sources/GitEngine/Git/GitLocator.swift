import Foundation

public struct GitInstallation: Sendable, Hashable, Codable {
    public var url: URL
    public var version: String
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(url: URL, version: String, major: Int, minor: Int, patch: Int) {
        self.url = url
        self.version = version
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public func isAtLeast(_ major: Int, _ minor: Int) -> Bool {
        (self.major, self.minor) >= (major, minor)
    }

    /// `git fetch --porcelain` exists since 2.41.
    public var supportsFetchPorcelain: Bool { isAtLeast(2, 41) }
    /// Hard floor: `rev-parse --path-format=absolute`, used by validate() and pull(), landed in
    /// 2.31. Older git does not reject the unknown flag — it echoes it as an extra first line
    /// and exits 0, so every parsed field shifts by one and repositories register as "/false".
    public var isSupported: Bool { isAtLeast(2, 31) }

    /// Parses "git version 2.50.1 (Apple Git-155)".
    public static func parseVersion(_ text: String, url: URL) -> GitInstallation? {
        let pattern = /git version (\d+)\.(\d+)(?:\.(\d+))?/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let major = Int(match.1) ?? 0
        let minor = Int(match.2) ?? 0
        let patch = match.3.flatMap { Int($0) } ?? 0
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "git version ", with: "")
        return GitInstallation(url: url, version: version, major: major, minor: minor, patch: patch)
    }
}

/// Finds a usable git binary without ever triggering the "install the command line developer tools" dialog.
public struct GitLocator: Sendable {
    public var runner: any ProcessRunning
    /// Extra candidates tried first (tests point this at a fake git script).
    public var extraCandidates: [URL]

    public init(runner: any ProcessRunning = FoundationProcessRunner(), extraCandidates: [URL] = []) {
        self.runner = runner
        self.extraCandidates = extraCandidates
    }

    private var fileManager: FileManager { .default }

    /// Fixed candidates, in priority order. `/usr/bin/git` is deliberately absent: it is a shim that
    /// pops a dialog when no developer tools are installed; the real binaries are listed instead.
    public static let fixedCandidates: [String] = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]

    public func candidates(override: URL?) async -> [URL] {
        var result: [URL] = []
        if let override { result.append(override) }
        result += extraCandidates
        result += Self.fixedCandidates.map { URL(fileURLWithPath: $0) }
        if let developerDir = await xcodeSelectPath() {
            result.append(developerDir.appending(path: "usr/bin/git"))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    public func locate(override: URL?) async -> GitInstallation? {
        for candidate in await candidates(override: override) {
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            if let installation = await probe(candidate), installation.isSupported {
                return installation
            }
        }
        return nil
    }

    /// Runs `git --version` with a short timeout.
    public func probe(_ url: URL) async -> GitInstallation? {
        let spec = ProcessSpec(
            executable: url,
            arguments: ["--version"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
            timeout: .seconds(5)
        )
        guard let result = try? await runner.run(spec), result.succeeded else { return nil }
        return GitInstallation.parseVersion(result.stdoutText, url: url)
    }

    private func xcodeSelectPath() async -> URL? {
        let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
        guard fileManager.isExecutableFile(atPath: xcodeSelect.path) else { return nil }
        let spec = ProcessSpec(executable: xcodeSelect, arguments: ["-p"], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5))
        guard let result = try? await runner.run(spec), result.succeeded else { return nil }
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
