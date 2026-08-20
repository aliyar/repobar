import Foundation

/// Parsed `git status --porcelain=v2 --branch -z` output.
public struct StatusV2: Sendable, Hashable {
    public var head: HeadState
    /// Short upstream name as git prints it (e.g. "origin/main"); ambiguous to split — use for-each-ref instead.
    public var upstream: String?
    /// Present only when the upstream is configured *and* its commit exists locally.
    public var aheadBehind: BranchComparison?
    public var workingTree: WorkingTreeState

    public init(head: HeadState, upstream: String?, aheadBehind: BranchComparison?, workingTree: WorkingTreeState) {
        self.head = head
        self.upstream = upstream
        self.aheadBehind = aheadBehind
        self.workingTree = workingTree
    }
}

public enum StatusV2Parser {
    public static func parse(_ data: Data) throws -> StatusV2 {
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> StatusV2 {
        // Records are NUL-terminated; rename entries are followed by one extra NUL-terminated token (origPath).
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var oid: String?
        var headName: String?
        var upstream: String?
        var aheadBehind: BranchComparison?
        var tree = WorkingTreeState()

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.hasPrefix("# ") {
                let body = token.dropFirst(2)
                if body.hasPrefix("branch.oid ") {
                    oid = String(body.dropFirst("branch.oid ".count))
                } else if body.hasPrefix("branch.head ") {
                    headName = String(body.dropFirst("branch.head ".count))
                } else if body.hasPrefix("branch.upstream ") {
                    upstream = String(body.dropFirst("branch.upstream ".count))
                } else if body.hasPrefix("branch.ab ") {
                    let parts = body.dropFirst("branch.ab ".count).split(separator: " ")
                    guard parts.count == 2,
                          let ahead = Int(parts[0].dropFirst()), let behind = Int(parts[1].dropFirst()) else {
                        throw ParseError.malformed("branch.ab: \(token)")
                    }
                    aheadBehind = BranchComparison(ahead: ahead, behind: behind)
                }
                continue
            }
            guard let first = token.first else { continue }
            switch first {
            case "1", "2":
                let fields = token.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 2, fields[1].count == 2 else { throw ParseError.malformed("entry: \(token)") }
                let xy = Array(fields[1])
                if xy[0] != "." { tree.staged += 1 }
                if xy[1] != "." { tree.unstaged += 1 }
                if first == "2" { index += 1 } // consume origPath token
            case "u":
                tree.conflicted += 1
            case "?":
                tree.untracked += 1
            case "!":
                break // ignored files (only with --ignored)
            default:
                break
            }
        }

        guard let oid, let headName else { throw ParseError.malformed("missing branch headers") }
        let head: HeadState
        if headName == "(detached)" {
            head = .detached(sha: oid)
        } else if oid == "(initial)" {
            head = .unborn(name: headName)
        } else {
            head = .branch(name: headName, sha: oid)
        }
        return StatusV2(head: head, upstream: upstream, aheadBehind: aheadBehind, workingTree: tree)
    }
}
