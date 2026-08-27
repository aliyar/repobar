import Foundation

/// User-facing classification of everything that can go wrong while checking a repository.
public enum RepoError: Codable, Sendable, Hashable {
    public enum AuthKind: String, Codable, Sendable { case ssh, https }

    case repoMissing
    case gitNotFound
    case timeout(seconds: Int)
    case lockConflict
    case notARepository
    case dubiousOwnership
    case hostKeyVerification
    case authFailed(AuthKind)
    case repositoryNotFound
    case noRemote
    case remoteRefNotFound(branch: String?)
    case tlsError
    case networkUnreachable
    case serverError
    case badRevision
    case ffNotPossible
    case localChangesWouldBeOverwritten
    case operationInProgress
    case noDefaultBranch
    case ambiguousRemote([String])
    case unknown(String)

    public var title: String {
        switch self {
        case .repoMissing: "Folder not found"
        case .gitNotFound: "git not found"
        case .timeout(let seconds): "Timed out after \(seconds)s"
        case .lockConflict: "Another git process is running"
        case .notARepository: "Not a git repository"
        case .dubiousOwnership: "Git refuses this folder (safe.directory)"
        case .hostKeyVerification: "SSH host key not trusted"
        case .authFailed(.ssh): "SSH authentication failed"
        case .authFailed(.https): "HTTPS authentication failed"
        case .repositoryNotFound: "Repository not found or no access"
        case .noRemote: "No remote configured"
        case .remoteRefNotFound(let branch): branch.map { "Branch '\($0)' not found on remote" } ?? "Branch not found on remote"
        case .tlsError: "TLS certificate problem"
        case .networkUnreachable: "Host unreachable"
        case .serverError: "Server error"
        case .badRevision: "Unknown revision"
        case .ffNotPossible: "Cannot fast-forward: local branch has diverged"
        case .localChangesWouldBeOverwritten: "Pull refused: local changes would be overwritten"
        case .operationInProgress: "Merge or rebase in progress"
        case .noDefaultBranch: "Could not determine the remote's default branch"
        case .ambiguousRemote(let remotes): "Several remotes (\(remotes.joined(separator: ", "))) — choose one"
        case .unknown(let line): line
        }
    }

    public var hint: String? {
        switch self {
        case .repoMissing: "Is the drive mounted? The repository stays in the list until you remove it."
        case .gitNotFound: "Install the Xcode Command Line Tools or Homebrew git, or set the path in Settings › Advanced."
        case .dubiousOwnership: "Run: git config --global --add safe.directory <path>"
        case .hostKeyVerification: "Run `ssh -T git@<host>` once in Terminal to trust the host key."
        case .authFailed(.ssh): "Works in Terminal? Add your key to the agent: ssh-add --apple-use-keychain ~/.ssh/<key>"
        case .authFailed(.https): "Set up a credential helper, e.g. `gh auth setup-git`."
        case .remoteRefNotFound: "Change the watched branch from the repository's menu."
        case .networkUnreachable: "RepoBar retries automatically when the network is back."
        case .ffNotPossible: "Pull manually (merge or rebase) in your git client."
        case .localChangesWouldBeOverwritten: "Commit or stash your changes first."
        case .operationInProgress: "Finish or abort the operation in your git client."
        default: nil
        }
    }

    /// Drives the backoff policy.
    public var failureKind: FailureKind {
        switch self {
        case .authFailed, .hostKeyVerification, .repositoryNotFound, .tlsError: .auth
        case .timeout, .networkUnreachable, .serverError, .remoteRefNotFound, .noDefaultBranch: .network
        case .lockConflict: .lock
        case .repoMissing, .gitNotFound, .notARepository, .dubiousOwnership, .noRemote, .ambiguousRemote: .fatal
        case .badRevision, .ffNotPossible, .localChangesWouldBeOverwritten, .operationInProgress, .unknown: .user
        }
    }
}

/// Maps git/ssh stderr to `RepoError`. First match wins; patterns are case-insensitive.
public enum GitErrorClassifier {
    private struct Rule: Sendable {
        /// Compiled once with the table below, not per classification: every failing check
        /// used to rebuild all 67 patterns. NSRegularExpression is immutable and Sendable.
        let regex: NSRegularExpression?
        let error: RepoError
        init(_ pattern: String, _ error: RepoError) {
            self.regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.error = error
        }
    }

    private static let rules: [Rule] = [
        Rule(#"cannot change to '.*': No such file or directory"#, .repoMissing),
        Rule(#"Unable to create '.*\.lock'"#, .lockConflict),
        Rule(#"cannot lock ref"#, .lockConflict),
        Rule(#"Another git process seems to be running"#, .lockConflict),
        Rule(#"index\.lock"#, .lockConflict),
        Rule(#"fatal: not a git repository"#, .notARepository),
        Rule(#"detected dubious ownership"#, .dubiousOwnership),
        Rule(#"Host key verification failed"#, .hostKeyVerification),
        Rule(#"No (RSA|ECDSA|ED25519|DSA) host key is known"#, .hostKeyVerification),
        Rule(#"REMOTE HOST IDENTIFICATION HAS CHANGED"#, .hostKeyVerification),
        Rule(#"Permission denied \(publickey"#, .authFailed(.ssh)),
        Rule(#"Permission denied, please try again"#, .authFailed(.ssh)),
        Rule(#"sign_and_send_pubkey: signing failed"#, .authFailed(.ssh)),
        Rule(#"Too many authentication failures"#, .authFailed(.ssh)),
        Rule(#"no such identity"#, .authFailed(.ssh)),
        Rule(#"agent refused operation"#, .authFailed(.ssh)),
        Rule(#"Authentication failed for '"#, .authFailed(.https)),
        Rule(#"could not read (Username|Password) for '.*': terminal prompts disabled"#, .authFailed(.https)),
        Rule(#"The requested URL returned error: 40[13]"#, .authFailed(.https)),
        Rule(#"remote: Invalid username or (password|token)"#, .authFailed(.https)),
        Rule(#"remote: Support for password authentication was removed"#, .authFailed(.https)),
        Rule(#"remote: HTTP Basic: Access denied"#, .authFailed(.https)),
        Rule(#"remote: (Unauthorized|Forbidden)"#, .authFailed(.https)),
        Rule(#"remote: Repository not found"#, .repositoryNotFound),
        Rule(#"fatal: repository '.*' not found"#, .repositoryNotFound),
        Rule(#"ERROR: Repository not found"#, .repositoryNotFound),
        Rule(#"access denied or repository not exported"#, .repositoryNotFound),
        Rule(#"The project you were looking for could not be found"#, .repositoryNotFound),
        Rule(#"remote: Not Found"#, .repositoryNotFound),
        Rule(#"'.+' does not appear to be a git repository"#, .noRemote),
        Rule(#"error: No such remote '"#, .noRemote),
        Rule(#"couldn't find remote ref"#, .remoteRefNotFound(branch: nil)),
        Rule(#"SSL certificate problem"#, .tlsError),
        Rule(#"SSL_ERROR"#, .tlsError),
        Rule(#"unable to get local issuer certificate"#, .tlsError),
        Rule(#"server certificate verification failed"#, .tlsError),
        Rule(#"Could not resolve host"#, .networkUnreachable),
        Rule(#"Could not resolve hostname"#, .networkUnreachable),
        Rule(#"nodename nor servname provided"#, .networkUnreachable),
        Rule(#"Temporary failure in name resolution"#, .networkUnreachable),
        Rule(#"Network is unreachable"#, .networkUnreachable),
        Rule(#"No route to host"#, .networkUnreachable),
        Rule(#"Connection refused"#, .networkUnreachable),
        Rule(#"Failed to connect to .* port"#, .networkUnreachable),
        Rule(#"Couldn't connect to server"#, .networkUnreachable),
        Rule(#"Operation timed out"#, .networkUnreachable),
        Rule(#"Connection timed out"#, .networkUnreachable),
        Rule(#"Connection reset by peer"#, .networkUnreachable),
        Rule(#"(ssh|kex)_exchange_identification"#, .networkUnreachable),
        Rule(#"Connection closed by .* port"#, .networkUnreachable),
        Rule(#"unexpected disconnect while reading sideband packet"#, .networkUnreachable),
        Rule(#"early EOF"#, .networkUnreachable),
        Rule(#"the remote end hung up unexpectedly"#, .networkUnreachable),
        Rule(#"RPC failed; HTTP 5\d\d"#, .serverError),
        Rule(#"remote: Internal Server Error"#, .serverError),
        Rule(#"fatal: protocol error"#, .serverError),
        Rule(#"The requested URL returned error: 5\d\d"#, .serverError),
        Rule(#"bad revision '"#, .badRevision),
        Rule(#"Invalid symmetric difference expression"#, .badRevision),
        Rule(#"Invalid revision range"#, .badRevision),
        Rule(#"ambiguous argument '.*': unknown revision"#, .badRevision),
        Rule(#"bad object"#, .badRevision),
        Rule(#"Not possible to fast-forward, aborting"#, .ffNotPossible),
        Rule(#"Your local changes to the following files would be overwritten"#, .localChangesWouldBeOverwritten),
        Rule(#"untracked working tree files would be overwritten"#, .localChangesWouldBeOverwritten),
        Rule(#"You have not concluded your merge"#, .operationInProgress),
        Rule(#"you need to resolve your current index first"#, .operationInProgress),
    ]

    public static func classify(stderr: String) -> RepoError {
        let range = NSRange(stderr.startIndex..., in: stderr)
        for rule in rules {
            guard let regex = rule.regex else { continue }
            if regex.firstMatch(in: stderr, range: range) != nil { return rule.error }
        }
        let firstLine = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "git failed"
        var message = firstLine
        for prefix in ["fatal: ", "error: ", "warning: "] where message.hasPrefix(prefix) {
            message.removeFirst(prefix.count)
        }
        return .unknown(String(message.prefix(200)))
    }
}
