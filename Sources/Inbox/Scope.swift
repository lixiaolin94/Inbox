import Foundation

/// The active Scope (PRD §6.6, §7). Determines both the search range and the
/// Project a newly created Record is written to — there is no separate
/// Project selector anywhere else in the UI.
enum Scope: Equatable {
    case all
    case project(id: String)

    /// `project_id` to write on a Record created while this Scope is active:
    /// nil (Inbox) for `.all`, the Project's id for `.project`.
    var createTargetProjectID: String? {
        switch self {
        case .all: return nil
        case .project(let id): return id
        }
    }
}
