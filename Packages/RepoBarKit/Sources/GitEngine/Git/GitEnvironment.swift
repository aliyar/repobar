import Foundation

/// Builds the environment for git subprocesses launched from a GUI app.
public enum GitEnvironment {
    /// Variables that would make a background timer pop dialogs or poison repository discovery.
    public static let removedKeys: Set<String> = [
        "GIT_ASKPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY",
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES",
        "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    ]

    public static let defaultSearchPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "~/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public static let sshBatchCommand = "ssh -o BatchMode=yes -o ConnectTimeout=15"

    /// - Parameters:
    ///   - base: usually `ProcessInfo.processInfo.environment` (keeps HOME, USER, TMPDIR, SSH_AUTH_SOCK…).
    ///   - gitExecutable: its directory is put first on PATH so helpers next to it resolve.
    ///   - extraPaths: user-configured additional PATH entries (Settings › Advanced).
    ///   - sshBatchMode: set `GIT_SSH_COMMAND` with BatchMode — only when the user has not configured
    ///     `core.sshCommand`/`GIT_SSH_COMMAND` themselves (the env var would override their setting).
    ///   - fileManager: for existence checks (injected in tests).
    public static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        gitExecutable: URL,
        extraPaths: [String] = [],
        sshBatchMode: Bool,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var env = base
        for key in removedKeys { env.removeValue(forKey: key) }

        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["LANG"] = "C"

        let home = base["HOME"] ?? NSHomeDirectory()
        var paths: [String] = [gitExecutable.deletingLastPathComponent().path]
        paths += extraPaths
        paths += defaultSearchPaths
        if let basePath = base["PATH"] { paths += basePath.split(separator: ":").map(String.init) }
        var seen = Set<String>()
        let resolved = paths
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted && fileManager.fileExists(atPath: $0) }
        env["PATH"] = resolved.joined(separator: ":")

        if sshBatchMode, base["GIT_SSH"] == nil, base["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = sshBatchCommand
        }
        return env
    }
}
