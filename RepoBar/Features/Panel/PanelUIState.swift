import Foundation
import Observation
import GitEngine

/// Ephemeral panel state that survives popover close/reopen.
@Observable
final class PanelUIState {
    var expanded: Set<RepoID> = []
    var searchText = ""
    var isDropTargeted = false
    var confirmingRemoval: RepoID?
    /// Keyboard selection. Nil until the first arrow key.
    var selected: RepoID?

    func toggle(_ id: RepoID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Moves the selection by `delta`, starting at either end when nothing is selected.
    /// Returns the newly selected repository, if any.
    @discardableResult
    func moveSelection(_ delta: Int, in ids: [RepoID]) -> RepoID? {
        guard !ids.isEmpty else { return nil }
        guard let current = selected, let index = ids.firstIndex(of: current) else {
            selected = delta > 0 ? ids.first : ids.last
            return selected
        }
        selected = ids[min(max(index + delta, 0), ids.count - 1)]
        return selected
    }

    /// Drops a selection that the current filter no longer shows.
    func pruneSelection(to ids: [RepoID]) {
        if let selected, !ids.contains(selected) { self.selected = nil }
    }
}
