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
        result.port = nil
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
        guard let url = URL(string: "\(webScheme)://\(parsed.host)/\(parsed.path)") else { return nil }
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
