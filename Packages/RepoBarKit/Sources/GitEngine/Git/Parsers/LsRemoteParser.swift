import Foundation

public enum LsRemoteParser {
    /// `git ls-remote --symref <remote> HEAD` → "ref: refs/heads/main\tHEAD" → "main".
    public static func parseSymrefHead(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("ref: ") else { continue }
            let parts = line.dropFirst("ref: ".count).split(separator: "\t")
            guard let target = parts.first, parts.count >= 2, parts[1] == "HEAD" else { continue }
            if target.hasPrefix("refs/heads/") { return String(target.dropFirst("refs/heads/".count)) }
        }
        return nil
    }

    /// `git ls-remote --heads <remote> [pattern]` → [(sha, refname)].
    public static func parseRefs(_ text: String) -> [(sha: String, ref: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0].count >= 7 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}
