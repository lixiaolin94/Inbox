import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class ListRowTests: XCTestCase {

    private func record(_ id: String, projectID: String? = nil, status: Int = 0) -> Record {
        Record(
            id: id,
            content: id,
            priority: 2,
            status: status,
            projectID: projectID,
            createdAt: 0,
            updatedAt: 0,
            resolvedAt: status == RecordStatus.resolved.rawValue ? 1 : nil,
            deletedAt: nil
        )
    }

    private func project(_ id: String, name: String, order: Int64) -> Project {
        Project(id: id, name: name, manualOrder: order, createdAt: 0, updatedAt: 0)
    }

    // MARK: - Ungrouped (Project Scope)

    func testUngroupedIsFlatRecordSequence() {
        let records = [record("a"), record("b")]
        let rows = ListRows.build(
            records: records,
            projects: [project("p", name: "P", order: 0)],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false }
        )
        XCTAssertEqual(rows, [.record(records[0]), .record(records[1])])
    }

    // MARK: - Grouped (All Scope)

    func testGroupedOrderIsInboxThenProjectsByManualOrder() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let p2 = project("p2", name: "Whisper", order: 1)
        let inboxA = record("i1")
        let inboxB = record("i2")
        let inP1 = record("r1", projectID: "p1")
        let inP2 = record("r2", projectID: "p2")

        // Input order is newest-first from search; grouping preserves it
        // inside each bucket.
        let rows = ListRows.build(
            records: [inboxA, inP2, inP1, inboxB],
            projects: [p1, p2],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { _ in false }
        )

        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(inboxA),
            .record(inboxB),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .record(inP1),
            .groupHeader(.project("p2"), title: "Whisper", isCollapsed: false),
            .record(inP2)
        ])
    }

    func testEmptyGroupsAreShownWhenNotSearching() {
        let p1 = project("p1", name: "Empty", order: 0)
        let rows = ListRows.build(
            records: [],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { _ in false }
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .groupHeader(.project("p1"), title: "Empty", isCollapsed: false)
        ])
    }

    func testEmptyGroupsAreHiddenWhenSearching() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let p2 = project("p2", name: "Whisper", order: 1)
        let match = record("hit", projectID: "p1")

        let rows = ListRows.build(
            records: [match],
            projects: [p1, p2],
            grouped: true,
            hideEmptyGroups: true,
            isCollapsed: { _ in false }
        )
        XCTAssertEqual(rows, [
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .record(match)
        ])
    }

    func testSearchingHidesInboxWhenItHasNoMatches() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let match = record("hit", projectID: "p1")
        let rows = ListRows.build(
            records: [match],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: true,
            isCollapsed: { _ in false }
        )
        XCTAssertFalse(rows.contains { $0.groupID == .inbox })
    }

    func testCollapsedGroupEmitsHeaderButNoRecords() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let inbox = record("i1")
        let inP1 = record("r1", projectID: "p1")

        let rows = ListRows.build(
            records: [inbox, inP1],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { id in
                if case .project("p1") = id { return true }
                return false
            }
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(inbox),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: true)
        ])
    }

    func testCollapsedInboxHidesInboxRecords() {
        let inbox = record("i1")
        let rows = ListRows.build(
            records: [inbox],
            projects: [],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { $0 == .inbox }
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: true)
        ])
    }

    func testCollapsedGroupWithSearchMatchesStillShowsHeader() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let match = record("hit", projectID: "p1")
        let rows = ListRows.build(
            records: [match],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: true,
            isCollapsed: { _ in true }
        )
        XCTAssertEqual(rows, [
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: true)
        ])
    }

    // MARK: - Index mapping

    func testTableRowLookupSkipsHeadersAndCollapsedRecords() {
        let p1 = project("p1", name: "P", order: 0)
        let inbox = record("i1")
        let hidden = record("h1", projectID: "p1")
        let rows = ListRows.build(
            records: [inbox, hidden],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { id in
                if case .project = id { return true }
                return false
            }
        )
        XCTAssertEqual(ListRowIndex.tableRow(forRecordID: "i1", in: rows), 1)
        XCTAssertNil(ListRowIndex.tableRow(forRecordID: "h1", in: rows))
        XCTAssertEqual(ListRowIndex.record(atTableRow: 1, in: rows)?.id, "i1")
        XCTAssertNil(ListRowIndex.record(atTableRow: 0, in: rows))
        XCTAssertEqual(ListRowIndex.visibleRecords(in: rows).map(\.id), ["i1"])
    }

    // MARK: - Show Resolved (PRD §11)

    func testUngroupedShowResolvedSplitsOpenThenResolved() {
        let openA = record("oa")
        let openB = record("ob")
        let resolvedA = record("ra", status: 1)
        let resolvedB = record("rb", status: 1)
        // Mixed input: grouping unmixed by status, preserving relative order.
        let rows = ListRows.build(
            records: [resolvedA, openA, resolvedB, openB],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .record(openA),
            .record(openB),
            .resolvedSectionHeader,
            .record(resolvedA),
            .record(resolvedB)
        ])
    }

    func testShowResolvedOffDropsResolvedRecords() {
        let open = record("o")
        let resolved = record("r", status: 1)
        let rows = ListRows.build(
            records: [open, resolved],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: false
        )
        XCTAssertEqual(rows, [.record(open)])
    }

    func testNoResolvedHeaderWhenThereAreNoResolvedRecords() {
        let open = record("o")
        let rows = ListRows.build(
            records: [open],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [.record(open)])
    }

    func testResolvedOnlyListStillEmitsSectionHeader() {
        let resolved = record("r", status: 1)
        let rows = ListRows.build(
            records: [resolved],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .resolvedSectionHeader,
            .record(resolved)
        ])
    }

    func testGroupedAllViewSplitsOpenThenResolvedInsideEachProject() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let inboxOpen = record("io")
        let inboxResolved = record("ir", status: 1)
        let p1Open = record("po", projectID: "p1")
        let p1Resolved = record("pr", projectID: "p1", status: 1)

        let rows = ListRows.build(
            records: [inboxResolved, p1Resolved, inboxOpen, p1Open],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(inboxOpen),
            .resolvedSectionHeader,
            .record(inboxResolved),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .record(p1Open),
            .resolvedSectionHeader,
            .record(p1Resolved)
        ])
    }

    func testSearchHidesEmptyGroupsEvenWhenOnlyResolvedWouldHaveMatched() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let p2 = project("p2", name: "Whisper", order: 1)
        let match = record("hit", projectID: "p1", status: 1)

        let rows = ListRows.build(
            records: [match],
            projects: [p1, p2],
            grouped: true,
            hideEmptyGroups: true,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .resolvedSectionHeader,
            .record(match)
        ])
        XCTAssertFalse(rows.contains { $0.groupID == .inbox })
        XCTAssertFalse(rows.contains { $0.groupID == .project("p2") })
    }

    func testCollapsedGroupHidesResolvedSubsection() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let open = record("o", projectID: "p1")
        let resolved = record("r", projectID: "p1", status: 1)
        let rows = ListRows.build(
            records: [open, resolved],
            projects: [p1],
            grouped: true,
            hideEmptyGroups: false,
            isCollapsed: { _ in true },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: true),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: true)
        ])
    }

    func testReopenMovesRecordBackToOpenGroup() {
        let open = record("keep")
        let reopened = record("back")
        let stillResolved = record("stay", status: 1)
        let rows = ListRows.build(
            records: [open, reopened, stillResolved],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows, [
            .record(open),
            .record(reopened),
            .resolvedSectionHeader,
            .record(stillResolved)
        ])
    }

    func testResolvedSectionHeaderIsSkippedByRecordMapping() {
        let open = record("o")
        let resolved = record("r", status: 1)
        let rows = ListRows.build(
            records: [open, resolved],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(ListRowIndex.record(atTableRow: 1, in: rows))
        XCTAssertEqual(ListRowIndex.tableRow(forRecordID: "o", in: rows), 0)
        XCTAssertEqual(ListRowIndex.tableRow(forRecordID: "r", in: rows), 2)
        XCTAssertEqual(ListRowIndex.visibleRecords(in: rows).map(\.id), ["o", "r"])
    }

    func testMainListBuilderDropsTrashedRecordsEvenWithShowResolved() {
        let open = record("o")
        let resolved = record("r", status: 1)
        let trashed = record("t", status: 2)
        let rows = ListRows.build(
            records: [open, resolved, trashed],
            projects: [],
            grouped: false,
            hideEmptyGroups: false,
            isCollapsed: { _ in false },
            showResolved: true
        )
        XCTAssertEqual(rows.map { $0.record?.id }, ["o", nil, "r"])
    }

    // MARK: - Trash grouping (PRD §12)

    func testTrashRowsGroupInboxThenProjectsAndOmitEmptyGroups() {
        let p1 = project("p1", name: "OMotion", order: 0)
        let p2 = project("p2", name: "Whisper", order: 1)
        let inboxA = record("i1", status: 2)
        let inboxB = record("i2", status: 2)
        let inP1 = record("r1", projectID: "p1", status: 2)

        let rows = TrashRows.build(
            records: [inboxA, inP1, inboxB],
            projects: [p1, p2]
        )
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(inboxA),
            .record(inboxB),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .record(inP1)
        ])
    }

    func testTrashRowsEmptyWhenNothingTrashed() {
        let p1 = project("p1", name: "OMotion", order: 0)
        XCTAssertEqual(TrashRows.build(records: [], projects: [p1]), [])
    }

    func testTrashRowsPreserveInputOrderInsideGroup() {
        let newer = record("new", status: 2)
        let older = record("old", status: 2)
        let rows = TrashRows.build(records: [newer, older], projects: [])
        XCTAssertEqual(rows, [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(newer),
            .record(older)
        ])
    }

    // MARK: - Drop target group (All View drag-to-move)

    /// rows: [Inbox header, a, b, P1 header, c]
    private var dropRows: [ListRow] {
        [
            .groupHeader(.inbox, title: "Inbox", isCollapsed: false),
            .record(record("a")),
            .record(record("b")),
            .groupHeader(.project("p1"), title: "OMotion", isCollapsed: false),
            .record(record("c", projectID: "p1"))
        ]
    }

    func testDropOnRecordResolvesToItsGroup() {
        XCTAssertEqual(ListRowIndex.dropTargetGroup(forCandidateRow: 2, in: dropRows)?.groupID, .inbox)
        XCTAssertEqual(ListRowIndex.dropTargetGroup(forCandidateRow: 4, in: dropRows)?.groupID, .project("p1"))
    }

    func testDropOnHeaderResolvesToThatGroup() {
        let target = ListRowIndex.dropTargetGroup(forCandidateRow: 3, in: dropRows)
        XCTAssertEqual(target?.groupID, .project("p1"))
        XCTAssertEqual(target?.headerRow, 3)
    }

    func testDropPastEndClampsToLastGroup() {
        XCTAssertEqual(ListRowIndex.dropTargetGroup(forCandidateRow: 99, in: dropRows)?.groupID, .project("p1"))
    }

    func testDropAboveEverythingHasNoTarget() {
        XCTAssertNil(ListRowIndex.dropTargetGroup(forCandidateRow: -1, in: dropRows))
        XCTAssertNil(ListRowIndex.dropTargetGroup(forCandidateRow: 0, in: []))
    }
}
