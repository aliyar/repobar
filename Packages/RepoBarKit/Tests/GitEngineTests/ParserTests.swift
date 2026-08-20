import Foundation
import Testing
@testable import GitEngine

@Suite("StatusV2Parser")
struct StatusV2ParserTests {
    @Test func parsesBranchWithUpstreamAndAheadBehind() throws {
        let text = "# branch.oid 604cffd5e7fbeb4589c290d425f65f78972b18b4\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -3\0"
        let status = try StatusV2Parser.parse(text)
        #expect(status.head == .branch(name: "main", sha: "604cffd5e7fbeb4589c290d425f65f78972b18b4"))
        #expect(status.upstream == "origin/main")
        #expect(status.aheadBehind == BranchComparison(ahead: 2, behind: 3))
        #expect(status.workingTree == WorkingTreeState())
    }

    @Test func upstreamWithoutAheadBehindWhenNeverFetched() throws {
        let text = "# branch.oid abc\0# branch.head feature\0# branch.upstream origin/feature\0"
        let status = try StatusV2Parser.parse(text)
        #expect(status.upstream == "origin/feature")
        #expect(status.aheadBehind == nil)
    }

    @Test func detachedAndUnborn() throws {
        let detached = try StatusV2Parser.parse("# branch.oid abc123\0# branch.head (detached)\0")
        #expect(detached.head == .detached(sha: "abc123"))
        let unborn = try StatusV2Parser.parse("# branch.oid (initial)\0# branch.head main\0")
        #expect(unborn.head == .unborn(name: "main"))
    }

    @Test func countsEntriesAndConsumesRenameOrigPath() throws {
        let entries = [
            "# branch.oid abc\0# branch.head main\0",
            "1 .M N... 100644 100644 100644 1111 2222 file-unstaged.txt\0",
            "1 M. N... 100644 100644 100644 1111 2222 file-staged.txt\0",
            "1 MM N... 100644 100644 100644 1111 2222 file-both.txt\0",
            "2 R. N... 100644 100644 100644 1111 2222 R100 new-name.txt\0old-name.txt\0",
            "u UU N... 100644 100644 100644 100644 1111 2222 3333 conflicted.txt\0",
            "? untracked-a.txt\0? untracked-b.txt\0",
        ].joined()
        let status = try StatusV2Parser.parse(entries)
        #expect(status.workingTree.staged == 3)    // staged, both, rename
        #expect(status.workingTree.unstaged == 2)  // unstaged, both
        #expect(status.workingTree.conflicted == 1)
        #expect(status.workingTree.untracked == 2)
        #expect(status.workingTree.isDirty)
    }

    @Test func missingHeadersThrows() {
        #expect(throws: ParseError.self) { try StatusV2Parser.parse("? foo\0") }
    }
}

@Suite("LogParser")
struct LogParserTests {
    @Test func parsesRecordsWithSeparators() throws {
        let record1 = ["a1b2c3d4e5f6", "a1b2c3d", "Ada Lovelace", "ada@example.com", "1700000000", "Fix crash on launch \"quoted\" 🚀"].joined(separator: "\u{1f}")
        let record2 = ["ffffffffffff", "fffffff", "Bot", "bot@example.com", "1700003600", "Bump deps\ttabbed"].joined(separator: "\u{1f}")
        let commits = try LogParser.parse(record1 + "\0" + record2 + "\0")
        #expect(commits.count == 2)
        #expect(commits[0].authorName == "Ada Lovelace")
        #expect(commits[0].subject == "Fix crash on launch \"quoted\" 🚀")
        #expect(commits[0].authorDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(commits[1].subject == "Bump deps\ttabbed")
        #expect(commits[1].isNew)
    }

    @Test func emptyOutputIsEmptyList() throws {
        #expect(try LogParser.parse("").isEmpty)
    }

    @Test func truncatedRecordThrows() {
        #expect(throws: ParseError.self) { try LogParser.parse("abc\u{1f}a\u{1f}Name\0") }
    }
}

@Suite("RevListParser")
struct RevListParserTests {
    @Test(arguments: [("0\t1\n", 0, 1), ("3\t0\n", 3, 0), ("12\t7", 12, 7)])
    func parsesLeftRight(text: String, left: Int, right: Int) throws {
        let result = try RevListParser.parseLeftRightCount(text)
        #expect(result.left == left)
        #expect(result.right == right)
    }

    @Test func garbageThrows() {
        #expect(throws: ParseError.self) { try RevListParser.parseLeftRightCount("fatal: bad revision") }
    }
}

@Suite("ForEachRefParser")
struct ForEachRefParserTests {
    @Test func parsesHeadsAndRemotes() {
        let text = [
            ["refs/heads/main", "604cff", "", "refs/remotes/origin/main", "origin", "refs/heads/main"].joined(separator: "\0"),
            ["refs/remotes/origin/HEAD", "604cff", "refs/remotes/origin/main", "", "", ""].joined(separator: "\0"),
            ["refs/remotes/origin/main", "604cff", "", "", "", ""].joined(separator: "\0"),
        ].joined(separator: "\n") + "\n"
        let records = ForEachRefParser.parse(text)
        #expect(records.count == 3)
        #expect(records[0].upstreamRemoteName == "origin")
        #expect(records[0].upstreamRemoteRef == "refs/heads/main")
        #expect(records[0].shortName == "main")
        #expect(records[1].symref == "refs/remotes/origin/main")
        #expect(records[2].upstream == nil)
    }

    @Test func localUpstreamUsesDotRemote() {
        let text = ["refs/heads/topic", "abc", "", "refs/heads/main", ".", "refs/heads/main"].joined(separator: "\0")
        let records = ForEachRefParser.parse(text)
        #expect(records.first?.upstreamRemoteName == ".")
    }

    @Test func emptyOutput() {
        #expect(ForEachRefParser.parse("").isEmpty)
    }
}

@Suite("LsRemoteParser")
struct LsRemoteParserTests {
    @Test func symrefHead() {
        let text = "ref: refs/heads/develop\tHEAD\n604cffd5e7fbeb4589c290d425f65f78972b18b4\tHEAD\n"
        #expect(LsRemoteParser.parseSymrefHead(text) == "develop")
        #expect(LsRemoteParser.parseSymrefHead("604cff\tHEAD\n") == nil)
    }

    @Test func heads() {
        let refs = LsRemoteParser.parseRefs("604cffd5e7fbeb4589c290d425f65f78972b18b4\trefs/heads/main\n")
        #expect(refs.count == 1)
        #expect(refs[0].ref == "refs/heads/main")
        #expect(LsRemoteParser.parseRefs("").isEmpty)
    }
}

@Suite("RevParseParser")
struct RevParseParserTests {
    @Test func normalRepo() throws {
        let text = "false\ntrue\nfalse\n/Users/x/proj\n/Users/x/proj/.git\n/Users/x/proj/.git\n"
        let v = try RevParseParser.parseValidation(text)
        #expect(v.toplevel == "/Users/x/proj")
        #expect(v.isBare == false)
        #expect(v.isShallow == false)
        #expect(v.isLinkedWorktree == false)
        #expect(v.superprojectWorkingTree == nil)
    }

    @Test func worktreeAndSubmodule() throws {
        let text = "false\ntrue\ntrue\n/Users/x/wt\n/Users/x/proj/.git/worktrees/wt\n/Users/x/proj/.git\n/Users/x/super\n"
        let v = try RevParseParser.parseValidation(text)
        #expect(v.isLinkedWorktree)
        #expect(v.isShallow)
        #expect(v.superprojectWorkingTree == "/Users/x/super")
    }

    @Test func tooShortThrows() {
        #expect(throws: ParseError.self) { try RevParseParser.parseValidation("false\ntrue\n") }
    }
}
