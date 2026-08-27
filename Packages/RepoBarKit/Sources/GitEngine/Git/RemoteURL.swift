import Foundation

/// A parsed git remote URL (scp-like, ssh://, https://, git://, file://).
public struct RemoteURL: Sendable, Hashable {
    public enum Scheme: String, Sendable { case ssh, https, http, git, file, local }

    public var scheme: Scheme
    /// Lowercased host with well-known SSH aliases resolved (e.g. ssh.github.com → github.com).
    public var host: String
    public var port: Int?
    /// "owner/repo" — no leading slash, no trailing slash or ".git".
    public var path: String

    public init(scheme: Scheme, host: String, port: Int? = nil, path: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    public static func parse(_ raw: String) -> RemoteURL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") {
            guard let components = URLComponents(string: text), let schemeText = components.scheme?.lowercased() else { return nil }
            let scheme: Scheme
            switch schemeText {
            case "ssh", "git+ssh", "ssh+git": scheme = .ssh
            case "https": scheme = .https
            case "http": scheme = .http
            case "git": scheme = .git
            case "file": return RemoteURL(scheme: .file, host: "", path: normalize(components.path))
            default: return nil
            }
            guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
            return resolveAliases(RemoteURL(scheme: scheme, host: host, port: components.port, path: normalize(components.path)))
        }

        // Local paths are not remotes we can map to the web.
        if text.hasPrefix("/") || text.hasPrefix(".") || text.hasPrefix("~") {
            return RemoteURL(scheme: .local, host: "", path: normalize(text))
        }

        // scp-like: [user@]host:path — the first ':' must come before any '/'.
        if let colon = text.firstIndex(of: ":") {
            let slash = text.firstIndex(of: "/")
            if slash == nil || colon < slash! {
                var hostPart = String(text[..<colon])
                if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
                let pathPart = String(text[text.index(after: colon)...])
                guard !hostPart.isEmpty, !pathPart.isEmpty else { return nil }
                return resolveAliases(RemoteURL(scheme: .ssh, host: hostPart.lowercased(), path: normalize(pathPart)))
            }
        }
        return nil
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        if p.lowercased().hasSuffix(".git") { p.removeLast(4) }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func resolveAliases(_ url: RemoteURL) -> RemoteURL {
        var result = url
        switch url.host {
        case "ssh.github.com": result.host = "github.com"
        case "altssh.gitlab.com": result.host = "gitlab.com"
        case "altssh.bitbucket.org": result.host = "bitbucket.org"
        case "ssh.dev.azure.com":
            // v3/org/project/repo → org/project/_git/repo
            result.host = "dev.azure.com"
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count == 4, parts[0] == "v3" {
                result.path = "\(parts[1])/\(parts[2])/_git/\(parts[3])"
            }
        default: break
        }
        // An ssh port never addresses the web UI, so it goes; an http(s) port usually is the
        // web UI (self-hosted Gitea/GitLab on :3000, :8443) and must be kept.
        if url.scheme != .http && url.scheme != .https { result.port = nil }
        return result
    }
}

/// Web URLs for a remote (repository page, commit pages, compare pages).
public struct WebRemote: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case github, gitlab, bitbucket, azureDevOps, gitea, sourcehut, unknown
    }

    public var kind: Kind
    public var repoURL: URL

    public init(kind: Kind, repoURL: URL) {
        self.kind = kind
        self.repoURL = repoURL
    }

    /// Builds web URLs from a git remote URL; `override` (a full https URL) wins when set.
    public static func from(remote: String, override: String? = nil) -> WebRemote? {
        if let override, let url = URL(string: override), let host = url.host() {
            return WebRemote(kind: kind(forHost: host.lowercased()), repoURL: url)
        }
        guard let parsed = RemoteURL.parse(remote), parsed.scheme != .file, parsed.scheme != .local, !parsed.path.isEmpty else { return nil }
        let webScheme = parsed.scheme == .http ? "http" : "https"
        let authority = parsed.port.map { "\(parsed.host):\($0)" } ?? parsed.host
        guard let url = URL(string: "\(webScheme)://\(authority)/\(parsed.path)") else { return nil }
        return WebRemote(kind: kind(forHost: parsed.host), repoURL: url)
    }

    public static func kind(forHost host: String) -> Kind {
        if host == "github.com" || host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        if host == "bitbucket.org" || host.contains("bitbucket") { return .bitbucket }
        if host == "dev.azure.com" || host.hasSuffix("visualstudio.com") { return .azureDevOps }
        if host == "codeberg.org" || host.contains("gitea") || host.contains("forgejo") { return .gitea }
        if host == "git.sr.ht" { return .sourcehut }
        return .unknown
    }

    public func commitURL(_ sha: String) -> URL {
        switch kind {
        case .gitlab: repoURL.appending(path: "-/commit/\(sha)")
        case .bitbucket: repoURL.appending(path: "commits/\(sha)")
        case .github, .gitea, .azureDevOps, .sourcehut, .unknown: repoURL.appending(path: "commit/\(sha)")
        }
    }

    public func compareURL(from base: String, to head: String) -> URL? {
        switch kind {
        case .github, .gitea: repoURL.appending(path: "compare/\(base)...\(head)")
        case .gitlab: repoURL.appending(path: "-/compare/\(base)...\(head)")
        case .bitbucket, .azureDevOps, .sourcehut, .unknown: nil
        }
    }
}

/// A page of a forge's web UI that RepoBar can link to. The engine only maps a page to a
/// URL; the visible title belongs to the app, which is why this is an enum and not a string.
public enum WebPage: String, Codable, Sendable, Hashable, CaseIterable {
    case pullRequests, issues, pipelines, branches, tags, releases
}

extension WebRemote {
    /// The page's URL, or nil when this forge has no such page or the path is not known
    /// well enough to build one. A link that cannot be built is never offered: a broken
    /// link is worse than a missing one.
    public func pageURL(_ page: WebPage) -> URL? {
        guard let path = Self.path(for: page, kind: kind) else { return nil }
        return repoURL.appending(path: path)
    }

    /// History of one branch.
    public func commitsURL(branch: String) -> URL? {
        guard !branch.isEmpty else { return nil }
        switch kind {
        case .github: return repoURL.appending(path: "commits/\(branch)")
        case .gitlab: return repoURL.appending(path: "-/commits/\(branch)")
        case .gitea, .bitbucket: return repoURL.appending(path: "commits/branch/\(branch)")
        case .sourcehut: return repoURL.appending(path: "log/\(branch)")
        case .azureDevOps, .unknown: return nil
        }
    }

    /// The "open a pull request from this branch" form. Offered only where the form fills
    /// the target branch in by itself — the others would need a base branch that RepoBar
    /// does not reliably know (the watched ref is not always the repository's default).
    public func newPullRequestURL(branch: String) -> URL? {
        guard !branch.isEmpty else { return nil }
        switch kind {
        case .github:
            return repoURL.appending(path: "pull/new/\(branch)")
        case .gitlab:
            let base = repoURL.appending(path: "-/merge_requests/new")
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: branch)]
            return components.url
        case .bitbucket, .gitea, .azureDevOps, .sourcehut, .unknown:
            return nil
        }
    }

    private static func path(for page: WebPage, kind: Kind) -> String? {
        switch kind {
        case .github, .gitea:
            switch page {
            case .pullRequests: "pulls"
            case .issues: "issues"
            case .pipelines: "actions"
            case .branches: "branches"
            case .tags: "tags"
            case .releases: "releases"
            }
        case .gitlab:
            switch page {
            case .pullRequests: "-/merge_requests"
            case .issues: "-/issues"
            case .pipelines: "-/pipelines"
            case .branches: "-/branches"
            case .tags: "-/tags"
            case .releases: "-/releases"
            }
        case .bitbucket:
            switch page {
            case .pullRequests: "pull-requests"
            case .issues: "issues"
            case .pipelines: "pipelines"
            case .branches: "branches"
            // Bitbucket Cloud has no releases page and files tags under a tab of /branches.
            case .tags, .releases: nil
            }
        case .azureDevOps:
            switch page {
            case .pullRequests: "pullrequests"
            case .branches: "branches"
            // Builds and work items live one level up, on the project, not the repository.
            case .issues, .pipelines, .tags, .releases: nil
            }
        case .sourcehut:
            switch page {
            case .branches: "refs"
            // Tickets and patches are on other sr.ht hosts, not on git.sr.ht.
            case .pullRequests, .issues, .pipelines, .tags, .releases: nil
            }
        case .unknown:
            nil
        }
    }
}
