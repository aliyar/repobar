import Foundation
import GitEngine

/// Row model: record + latest snapshot + transient UI flags.
nonisolated struct RepoItem: Identifiable, Equatable {
    enum Status: Equatable {
        case checking, unseen(Int), idle, error(RepoError), waitingForFirstCheck
    }

    var record: RepoRecord
    var snapshot: RepoSnapshot?
    var isChecking: Bool
    var color: RepoColor

    var id: RepoID { record.id }
    var name: String { record.name }
    var path: String { record.path }
    var unseen: Int { snapshot?.unseenCount ?? 0 }
    var behind: Int { snapshot?.behind ?? 0 }
    var ahead: Int { snapshot?.ahead ?? 0 }
    var isDirty: Bool { snapshot?.workingTree.isDirty ?? false }
    var error: RepoError? { snapshot?.error }
    var branchLabel: String? {
        switch snapshot?.head {
        case .branch(let name, _)?, .unborn(let name)?: name
        case .detached(let sha)?: "detached @ \(sha.prefix(7))"
        case nil: nil
        }
    }
    var watchedLabel: String? { snapshot?.watched?.key }
    var hasExpandableContent: Bool {
        !(snapshot?.incoming.isEmpty ?? true) || error != nil || snapshot?.watched != nil
    }

    var status: Status {
        if isChecking && snapshot == nil { return .checking }
        guard let snapshot else { return .waitingForFirstCheck }
        if let error = snapshot.error { return .error(error) }
        if snapshot.unseenCount > 0 { return .unseen(snapshot.unseenCount) }
        return .idle
    }

    var dot: RepoDot {
        RepoDot(id: id, color: color, unseen: unseen, hasError: error != nil)
    }
}

nonisolated enum RepoSorting {
    /// Unseen first (most first), then errors, then alphabetical.
    static func sort(_ items: [RepoItem]) -> [RepoItem] {
        items.sorted { lhs, rhs in
            if (lhs.unseen > 0) != (rhs.unseen > 0) { return lhs.unseen > 0 }
            if lhs.unseen != rhs.unseen { return lhs.unseen > rhs.unseen }
            if (lhs.error != nil) != (rhs.error != nil) { return lhs.error != nil }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.record.sortOrder < rhs.record.sortOrder
        }
    }

    static func filter(_ items: [RepoItem], query: String) -> [RepoItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.path.localizedCaseInsensitiveContains(needle)
                || ($0.branchLabel?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
}

nonisolated struct Toast: Equatable, Identifiable {
    enum Kind { case info, success, failure }
    var id = UUID()
    var message: String
    var kind: Kind = .info
}

nonisolated struct DiscoveryProposal: Equatable, Identifiable {
    var id = UUID()
    var folder: URL
    var repositories: [URL]
}
