import Foundation

/// A single Record. Timestamps are Unix milliseconds (Int64) so that several
/// Records created within the same second still sort deterministically.
struct Record: Equatable {
    let id: String
    var content: String
    var priority: Int
    var status: Int
    var projectID: String?
    let createdAt: Int64
    var updatedAt: Int64
    var resolvedAt: Int64?
    var deletedAt: Int64?
    /// Set only on the duplicate that a same-field content conflict produced
    /// (PRD §15.3 Keep Both): the id of the original it was copied from. The
    /// original stays unmarked; resolving the pair clears this.
    var conflictOf: String? = nil

    var priorityValue: Priority {
        Priority(rawValue: priority) ?? .p2
    }
}

/// Fixed P0–P3 priority. Default is P2. Text label is always shown; color is
/// an assist, never the sole way to distinguish priority.
enum Priority: Int, CaseIterable {
    case p0 = 0
    case p1 = 1
    case p2 = 2
    case p3 = 3

    var label: String { "P\(rawValue)" }

    /// One step toward P0 (PRD §8.4, `←`). Already at P0 stays at P0 — the
    /// boundary does not cycle.
    var raised: Priority {
        Priority(rawValue: rawValue - 1) ?? self
    }

    /// One step toward P3 (PRD §8.4, `→`). Already at P3 stays at P3.
    var lowered: Priority {
        Priority(rawValue: rawValue + 1) ?? self
    }
}

/// Direction of a Row Focus priority key press. `raise` is `←`, `lower` is `→`.
enum PriorityAdjustment {
    case raise
    case lower

    func apply(to priority: Priority) -> Priority {
        switch self {
        case .raise: return priority.raised
        case .lower: return priority.lowered
        }
    }
}

/// Record lifecycle state. Open and Resolved appear in the main list;
/// Trashed is the soft-deleted state (PRD §8.8, §12).
enum RecordStatus: Int {
    case open = 0
    case resolved = 1
    case trashed = 2
}
