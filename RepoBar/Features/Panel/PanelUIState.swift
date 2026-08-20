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

    func toggle(_ id: RepoID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
