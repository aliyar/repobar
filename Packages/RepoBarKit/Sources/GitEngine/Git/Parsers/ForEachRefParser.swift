import Foundation

/// One record of `git for-each-ref --format='%(refname)%00%(objectname)%00%(symref)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)'`.
public struct RefRecord: Sendable, Hashable {
    public var refname: String
    public var objectName: String
    public var symref: String?
    public var upstream: String?
    public var upstreamRemoteName: String?
    public var upstreamRemoteRef: String?

    public init(refname: String, objectName: String, symref: String? = nil, upstream: String? = nil, upstreamRemoteName: String? = nil, upstreamRemoteRef: String? = nil) {
        self.refname = refname
        self.objectName = objectName
        self.symref = symref
        self.upstream = upstream
        self.upstreamRemoteName = upstreamRemoteName
        self.upstreamRemoteRef = upstreamRemoteRef
    }

    /// "refs/heads/main" → "main"
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where refname.hasPrefix(prefix) {
            return String(refname.dropFirst(prefix.count))
        }
        return refname
    }
}

public enum ForEachRefParser {
    public static let format = "%(refname)%00%(objectname)%00%(symref)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)"

    public static func parse(_ text: String) -> [RefRecord] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, !fields[0].isEmpty else { return nil }
            func opt(_ value: String) -> String? { value.isEmpty ? nil : value }
            return RefRecord(
                refname: fields[0],
                objectName: fields[1],
                symref: opt(fields[2]),
                upstream: opt(fields[3]),
                upstreamRemoteName: opt(fields[4]),
                upstreamRemoteRef: opt(fields[5])
            )
        }
    }
}
