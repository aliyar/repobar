import Foundation

/// Parses `git log -z --format='%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s'`.
public enum LogParser {
    public static let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s"

    public static func parse(_ data: Data) throws -> [IncomingCommit] {
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> [IncomingCommit] {
        var commits: [IncomingCommit] = []
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            let trimmed = record.hasSuffix("\n") ? record.dropLast() : record[...]
            if trimmed.isEmpty { continue }
            let fields = trimmed.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, let timestamp = TimeInterval(fields[4]) else {
                throw ParseError.malformed("log record: \(String(trimmed.prefix(80)))")
            }
            commits.append(IncomingCommit(
                sha: fields[0],
                shortSHA: fields[1],
                authorName: fields[2],
                authorEmail: fields[3],
                authorDate: Date(timeIntervalSince1970: timestamp),
                subject: fields[5]
            ))
        }
        return commits
    }
}
