import Foundation

/// Global Record list sort (PRD §10). One setting for the whole app, not
/// per-Project. SQL and in-memory comparators use the same keys; ties at
/// equal `createdAt` use sqlite `rowid` in SQL and original order in memory
/// (stable) because `Record` does not carry rowid.
enum RecordSort: String, CaseIterable {
    case newestFirst
    case oldestFirst
    case priority

    var menuTitle: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .priority: return "Priority"
        }
    }

    var sqlOrderClause: String {
        switch self {
        case .newestFirst:
            return "ORDER BY created_at DESC, rowid DESC"
        case .oldestFirst:
            return "ORDER BY created_at ASC, rowid ASC"
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
        switch self {
        case .newestFirst:
            return compareCreatedAt(lhs, rhs, newestFirst: true)
        case .oldestFirst:
            return compareCreatedAt(lhs, rhs, newestFirst: false)
        case .priority:
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority ? .orderedAscending : .orderedDescending
            }
            return compareCreatedAt(lhs, rhs, newestFirst: true)
        }
    }

    private func compareCreatedAt(_ lhs: Record, _ rhs: Record, newestFirst: Bool) -> ComparisonResult {
        if lhs.createdAt == rhs.createdAt { return .orderedSame }
        let lhsNewer = lhs.createdAt > rhs.createdAt
        if newestFirst {
            return lhsNewer ? .orderedAscending : .orderedDescending
        }
        return lhsNewer ? .orderedDescending : .orderedAscending
    }
}
