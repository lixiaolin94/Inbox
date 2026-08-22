import Foundation

/// Global Record list sort (PRD §10): newest first, or by Priority. One
/// setting for the whole app, flipped by the utility bar's sort chip — a
/// two-state toggle, no menu. SQL and in-memory comparators use the same
/// keys; ties at equal `createdAt` use sqlite `rowid` in SQL and original
/// order in memory (stable) because `Record` does not carry rowid.
enum RecordSort: String, CaseIterable {
    case newestFirst
    case priority

    var chipTitle: String {
        switch self {
        case .newestFirst: return "Newest"
        case .priority: return "Priority"
        }
    }

    /// The chip flips between the two orders.
    var next: RecordSort {
        self == .newestFirst ? .priority : .newestFirst
    }

    var sqlOrderClause: String {
        switch self {
        case .newestFirst:
            return "ORDER BY created_at DESC, rowid DESC"
        case .priority:
            return "ORDER BY priority ASC, created_at DESC, rowid DESC"
        }
    }

    /// Display order inside one status group. Status grouping itself is
    /// ListRows' job (Open then Resolved); this only sorts by the current
    /// dimension.
    func sorted(_ records: [Record]) -> [Record] {
        records.enumerated()
            .sorted { lhs, rhs in
                switch compare(lhs.element, rhs.element) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    func compare(_ lhs: Record, _ rhs: Record) -> ComparisonResult {
        if self == .priority, lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority ? .orderedAscending : .orderedDescending
        }
        if lhs.createdAt == rhs.createdAt { return .orderedSame }
        return lhs.createdAt > rhs.createdAt ? .orderedAscending : .orderedDescending
    }
}
