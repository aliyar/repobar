import Foundation

public enum RevListParser {
    /// Parses `git rev-list --left-right --count A...B` → "left\tright".
    public static func parseLeftRightCount(_ text: String) throws -> (left: Int, right: Int) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let left = Int(parts[0]), let right = Int(parts[1]) else {
            throw ParseError.malformed("rev-list: \(text)")
        }
        return (left, right)
    }

}
