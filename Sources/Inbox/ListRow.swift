import Foundation

/// Identity of an All View group (PRD §7.2). Inbox is the NULL-`project_id`
/// group; every Project is its own group keyed by id.
enum GroupID: Equatable, Hashable {
    case inbox
    case project(String)
}

/// One row in the Record List table. In Project Scope this is a flat sequence
/// of `.record` rows (plus an optional Resolved subsection). In All Scope,
/// group headers wrap each bucket; Open and Resolved never mix inside a group.
enum ListRow: Equatable {
    case groupHeader(GroupID, title: String, isCollapsed: Bool)
    /// Lightweight, non-navigable label between Open and Resolved records
    /// inside one display group (PRD §11). Not a GroupID and not collapsible.
    case resolvedSectionHeader
    case record(Record)
}

/// Pure builder: records + projects + collapse/search flags → table rows.
/// All View grouping, keyboard navigation, Inline Edit, and Resolve inheritance
/// all read this sequence so row↔record mapping lives in one place.
///
/// Status grouping is this layer's job: when `showResolved` is on, each
/// display group emits Open records, then a `.resolvedSectionHeader`, then
/// Resolved records. Sort order is the caller's job — this preserves the
/// relative order of each status inside the input `records` array.
enum ListRows {
    /// - Parameter grouped: All Scope is grouped; Project Scope is not.
    /// - Parameter hideEmptyGroups: true while Universal Input has a search
    ///   term — a group with no matching records is omitted entirely.
    /// - Parameter isCollapsed: per-group fold state. Collapsed groups still
    ///   emit a header (when not hidden) but no record rows.
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

        let inboxRecords = visible.filter { $0.projectID == nil }
        appendGroup(
            to: &rows,
            id: .inbox,
            title: "Inbox",
            records: inboxRecords,
            hideIfEmpty: hideEmptyGroups,
            isCollapsed: isCollapsed(.inbox),
            showResolved: showResolved
        )

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

    /// Open records first, then an optional Resolved subsection. Relative
    /// order inside each status is the input order (already sorted by fetch
    /// or a local `RecordSort.sorted`).
    private static func recordRows(from records: [Record], showResolved: Bool) -> [ListRow] {
        if !showResolved {
            return records.map { .record($0) }
        }
        let open = records.filter { $0.status == RecordStatus.open.rawValue }
        let resolved = records.filter { $0.status == RecordStatus.resolved.rawValue }
        var rows = open.map { ListRow.record($0) }
        if !resolved.isEmpty {
            rows.append(.resolvedSectionHeader)
            rows.append(contentsOf: resolved.map { .record($0) })
        }
        return rows
    }
}

/// Trash surface grouping (PRD §12). Inbox first, then Projects in the
/// given (manual) order. Empty groups are omitted; headers are never
/// collapsed — the PRD does not require fold on this surface.
enum TrashRows {
    static func build(records: [Record], projects: [Project]) -> [ListRow] {
        var rows: [ListRow] = []

        let inbox = records.filter { $0.projectID == nil }
        if !inbox.isEmpty {
            rows.append(.groupHeader(.inbox, title: "Inbox", isCollapsed: false))
            rows.append(contentsOf: inbox.map { .record($0) })
        }

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
}
