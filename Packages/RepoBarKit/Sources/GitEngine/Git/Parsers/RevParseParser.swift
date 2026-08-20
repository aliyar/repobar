import Foundation

public enum RevParseParser {
    public static let validationFlags = [
        "--path-format=absolute",
        "--is-bare-repository",
        "--is-inside-work-tree",
        "--is-shallow-repository",
        "--show-toplevel",
        "--git-dir",
        "--git-common-dir",
        "--show-superproject-working-tree",
    ]

    /// Parses the output of `git rev-parse <validationFlags>`: one line per flag in order;
    /// `--show-superproject-working-tree` prints nothing at all when not a submodule (hence last).
    public static func parseValidation(_ text: String) throws -> RepoValidation {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 6 else { throw ParseError.malformed("rev-parse: expected ≥ 6 lines, got \(lines.count)") }
        return RepoValidation(
            toplevel: lines[3],
            gitDir: lines[4],
            gitCommonDir: lines[5],
            isBare: lines[0] == "true",
            isShallow: lines[2] == "true",
            superprojectWorkingTree: lines.count >= 7 ? lines[6] : nil
        )
    }
}
