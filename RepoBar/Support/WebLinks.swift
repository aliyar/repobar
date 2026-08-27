import Foundation
import GitEngine

/// Presentation for the engine's `WebPage`. The engine maps a page to a URL and stays free
/// of user-facing text; naming the pages and the forge belongs here.
nonisolated enum WebLinks {
    /// Pages offered in the repository's web submenu, grouped as they are shown. A group
    /// whose pages this forge does not have collapses away; the divider goes with it.
    static let groups: [[WebPage]] = [
        [.pullRequests, .issues, .pipelines],
        [.branches, .tags, .releases],
    ]

    static func title(_ page: WebPage, on kind: WebRemote.Kind) -> String {
        switch page {
        case .pullRequests: kind == .gitlab ? "Merge Requests" : "Pull Requests"
        case .issues: "Issues"
        case .pipelines: kind == .github || kind == .gitea ? "Actions" : "Pipelines"
        case .branches: "Branches"
        case .tags: "Tags"
        case .releases: "Releases"
        }
    }

    /// What to call the forge in the submenu title. An unrecognised host names itself,
    /// which says more than a generic word would.
    static func forgeName(_ web: WebRemote) -> String {
        switch web.kind {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .azureDevOps: "Azure DevOps"
        case .gitea, .sourcehut, .unknown: web.repoURL.host() ?? "Web"
        }
    }

    /// Title of the "start a pull request" item, in the words the forge uses.
    static func newPullRequestTitle(on kind: WebRemote.Kind) -> String {
        kind == .gitlab ? "New Merge Request…" : "New Pull Request…"
    }
}
