import Foundation

/// Identity of an All View group (PRD §7.2). Inbox is the NULL-`project_id`
/// group; every Project is its own group keyed by id.
enum GroupID: Equatable, Hashable {
    case inbox
    case project(String)
}

/// One row in the Record List table. In Project Scope this is a flat sequence
/// of `.record` rows. In All Scope, unassigned Records sit at the top with no
/// group header (so they are not confused with a Project named Inbox);
/// Project groups still have headers. Open and Resolved never mix inside a
/// group: Resolved rows follow the Open ones and are marked by their style.
enum ListRow: Equatable {
    case groupHeader(GroupID, title: String, isCollapsed: Bool)
    case record(Record)
}

/// Pure builder: records + projects + collapse/search flags → table rows.
/// All View grouping, keyboard navigation, Inline Edit, and Resolve inheritance
/// all read this sequence so row↔record mapping lives in one place.
///
/// Status grouping is this layer's job: when `showResolved` is on, each
/// display group emits Open records, then Resolved records. Sort order is
/// the caller's job — this preserves the relative order of each status
/// inside the input `records` array.
enum ListRows {
    /// - Parameter grouped: All Scope is grouped; Project Scope is not.
    /// - Parameter hideEmptyGroups: true while Universal Input has a search
    ///   term — a group with no matching records is omitted entirely.
    /// - Parameter isCollapsed: per-Project fold state. Collapsed groups still
    ///   emit a header (when not hidden) but no record rows. Unassigned
    ///   Records in All view have no header and ignore this.
    /// - Parameter showResolved: PRD §11. Off (default) drops Resolved
    ///   records. On splits each group Open → Resolved.
    static func build(
        records: [Record],
        projects: [Project],
        grouped: Bool,
        hideEmptyGroups: Bool,
        isCollapsed: (GroupID) -> Bool,
        showResolved: Bool = false
    ) -> [ListRow] {
        let visible = records.filter { isVisible($0, showResolved: showResolved) }

        guard grouped else {
            return recordRows(from: visible, showResolved: showResolved)
        }

        var rows: [ListRow] = []

        // Unassigned Records are the All-view default list: no "Inbox" header,
        // and they cannot be collapsed. An empty bucket emits nothing.
        let inboxRecords = visible.filter { $0.projectID == nil }
        if !inboxRecords.isEmpty {
            rows.append(contentsOf: recordRows(from: inboxRecords, showResolved: showResolved))
        }

        for project in projects {
            let groupRecords = visible.filter { $0.projectID == project.id }
            appendGroup(
                to: &rows,
                id: .project(project.id),
                title: project.name,
                records: groupRecords,
                hideIfEmpty: hideEmptyGroups,
                isCollapsed: isCollapsed(.project(project.id)),
                showResolved: showResolved
            )
        }

        return rows
    }

    private static func isVisible(_ record: Record, showResolved: Bool) -> Bool {
        if record.status == RecordStatus.open.rawValue { return true }
        if showResolved && record.status == RecordStatus.resolved.rawValue { return true }
        return false
    }

    private static func appendGroup(
        to rows: inout [ListRow],
        id: GroupID,
        title: String,
        records: [Record],
        hideIfEmpty: Bool,
        isCollapsed: Bool,
        showResolved: Bool
    ) {
        if hideIfEmpty && records.isEmpty { return }
        rows.append(.groupHeader(id, title: title, isCollapsed: isCollapsed))
        if !isCollapsed {
            rows.append(contentsOf: recordRows(from: records, showResolved: showResolved))
        }
    }

    /// Open records first, then Resolved ones (PRD: "Open 和 Resolved 始终
    /// 分组"). No header row: the strikethrough style already marks them.
    /// Relative order inside each status is the input order.
    private static func recordRows(from records: [Record], showResolved: Bool) -> [ListRow] {
        if !showResolved {
            return records.map { .record($0) }
        }
        let open = records.filter { $0.status == RecordStatus.open.rawValue }
        let resolved = records.filter { $0.status == RecordStatus.resolved.rawValue }
        return (open + resolved).map { .record($0) }
    }
}

/// Trash surface grouping (PRD §12). Inbox first, then Projects in the
/// given (manual) order. Empty groups are omitted; headers are never
/// collapsed — the PRD does not require fold on this surface.
enum TrashRows {
    static func build(records: [Record], projects: [Project]) -> [ListRow] {
        var rows: [ListRow] = []

        // Same rule as the All view: unassigned Records lead the list with
        // no "Inbox" header.
        rows.append(contentsOf: records.filter { $0.projectID == nil }.map { .record($0) })

        for project in projects {
            let group = records.filter { $0.projectID == project.id }
            if !group.isEmpty {
                rows.append(.groupHeader(.project(project.id), title: project.name, isCollapsed: false))
                rows.append(contentsOf: group.map { .record($0) })
            }
        }

        return rows
    }
}

extension ListRow {
    var record: Record? {
        if case .record(let record) = self { return record }
        return nil
    }

    var groupID: GroupID? {
        if case .groupHeader(let id, _, _) = self { return id }
        return nil
    }
}

enum ListRowIndex {
    /// Table row of the Record with `id`, if that Record is currently a
    /// visible (non-collapsed) row.
    static func tableRow(forRecordID id: String, in rows: [ListRow]) -> Int? {
        rows.firstIndex { $0.record?.id == id }
    }

    static func record(atTableRow row: Int, in rows: [ListRow]) -> Record? {
        guard rows.indices.contains(row) else { return nil }
        return rows[row].record
    }

    /// Visible Records in display order — the sequence ↑↓ and Resolve
    /// inheritance walk, skipping group headers.
    static func visibleRecords(in rows: [ListRow]) -> [Record] {
        rows.compactMap(\.record)
    }

    /// Drag & drop (All View): the group a proposed drop row belongs to,
    /// found by walking upward from `candidateRow` to the nearest group
    /// header. The headerless prefix (unassigned Records) is Inbox;
    /// `headerRow` is nil there because All view has no Inbox header.
    /// `candidateRow` may be past the end (drop below the last row —
    /// clamped) or −1 / above the first row (still Inbox). Empty `rows`
    /// has no target.
    static func dropTargetGroup(forCandidateRow candidateRow: Int, in rows: [ListRow]) -> (headerRow: Int?, groupID: GroupID)? {
        guard !rows.isEmpty else { return nil }
        var row = min(candidateRow, rows.count - 1)
        while row >= 0 {
            if let id = rows[row].groupID {
                return (headerRow: row, groupID: id)
            }
            row -= 1
        }
        return (headerRow: nil, groupID: .inbox)
    }
}
