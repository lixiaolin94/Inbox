import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class ConflictMergerTests: XCTestCase {
    private func record(
        content: String = "same",
        priority: Int = 2,
        status: Int = 0,
        projectID: String? = nil,
        createdAt: Int64 = 1000,
        updatedAt: Int64 = 1000,
        resolvedAt: Int64? = nil,
        deletedAt: Int64? = nil,
        conflictOf: String? = nil
    ) -> ConflictMerger.RecordFields {
        ConflictMerger.RecordFields(
            content: content,
            priority: priority,
            status: status,
            projectID: projectID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            resolvedAt: resolvedAt,
            deletedAt: deletedAt,
            conflictOf: conflictOf
        )
    }

    func testDifferentFieldsMergeAutomatically() {
        let ancestor = record(priority: 2, status: 0, updatedAt: 1000)
        let local = record(priority: 0, status: 0, updatedAt: 2000)
        let server = record(priority: 2, status: 1, updatedAt: 1500, resolvedAt: 1500)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(merged.content, "same")
        XCTAssertEqual(merged.priority, 0)
        XCTAssertEqual(merged.status, 1)
        XCTAssertEqual(merged.resolvedAt, 1500)
        XCTAssertEqual(merged.updatedAt, 2000)
    }

    func testContentConflictKeepsBoth() {
        let ancestor = record(content: "original", updatedAt: 1000)
        let local = record(content: "local edit", updatedAt: 2000)
        let server = record(content: "server edit", updatedAt: 1800)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .keepBoth(let serverVersion, let duplicate) = outcome else {
            return XCTFail("expected keepBoth, got \(outcome)")
        }
        XCTAssertEqual(serverVersion.content, "server edit")
        XCTAssertEqual(duplicate.content, "local edit")
        XCTAssertEqual(serverVersion.updatedAt, 2000)
        XCTAssertEqual(duplicate.updatedAt, 2000)
    }

    func testContentChangedOnOneSideOnlyTakesThatSide() {
        let ancestor = record(content: "original", updatedAt: 1000)
        let local = record(content: "original", updatedAt: 1000)
        let server = record(content: "server edit", updatedAt: 1800)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(merged.content, "server edit")
    }

    func testScalarSameFieldNewerUpdatedAtWins() {
        let ancestor = record(priority: 2, updatedAt: 1000)
        let local = record(priority: 0, updatedAt: 2500)
        let server = record(priority: 3, updatedAt: 1800)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(merged.priority, 0)
    }

    func testScalarSameFieldTimestampTieTakesServer() {
        let ancestor = record(priority: 2, updatedAt: 1000)
        let local = record(priority: 0, updatedAt: 2000)
        let server = record(priority: 3, updatedAt: 2000)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(merged.priority, 3)
    }

    func testNilAncestorTreatsEveryDifferenceAsConflict() {
        let local = record(content: "a", priority: 0, updatedAt: 3000)
        let server = record(content: "b", priority: 1, updatedAt: 2000)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: nil)
        guard case .keepBoth(let serverVersion, let duplicate) = outcome else {
            return XCTFail("expected keepBoth without ancestor, got \(outcome)")
        }
        XCTAssertEqual(serverVersion.content, "b")
        XCTAssertEqual(duplicate.content, "a")
        // Scalar conflict with no ancestor: newer local updatedAt wins.
        XCTAssertEqual(serverVersion.priority, 0)
        XCTAssertEqual(duplicate.priority, 0)
    }

    // MARK: - Conflict marker (conflictOf)

    func testConflictMarkerSurvivesUnrelatedMerge() {
        let ancestor = record(priority: 2, updatedAt: 1000, conflictOf: "orig")
        let local = record(priority: 0, updatedAt: 2000, conflictOf: "orig")
        let server = record(priority: 2, status: 1, updatedAt: 1500, resolvedAt: 1500, conflictOf: "orig")

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(merged.conflictOf, "orig")
        XCTAssertEqual(merged.priority, 0)
        XCTAssertEqual(merged.status, 1)
    }

    func testConflictMarkerClearedOnOneSidePropagates() {
        // The other device resolved the pair (cleared the marker); this
        // device only bumped priority. Both edits survive, marker stays gone.
        let ancestor = record(updatedAt: 1000, conflictOf: "orig")
        let local = record(priority: 0, updatedAt: 2000, conflictOf: "orig")
        let server = record(updatedAt: 1500, conflictOf: nil)

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .merged(let merged) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertNil(merged.conflictOf)
        XCTAssertEqual(merged.priority, 0)
    }

    func testKeepBothCarriesMergedMarkerOnBothCopies() {
        let ancestor = record(content: "original", updatedAt: 1000, conflictOf: "orig")
        let local = record(content: "local edit", updatedAt: 2000, conflictOf: "orig")
        let server = record(content: "server edit", updatedAt: 1800, conflictOf: "orig")

        let outcome = ConflictMerger.mergeRecord(local: local, server: server, ancestor: ancestor)
        guard case .keepBoth(let serverVersion, let duplicate) = outcome else {
            return XCTFail("expected keepBoth, got \(outcome)")
        }
        XCTAssertEqual(serverVersion.conflictOf, "orig")
        XCTAssertEqual(duplicate.conflictOf, "orig")
    }

    func testAncestorJSONWithoutConflictOfStillDecodes() {
        // Pre-v4 ck_system_fields snapshots have no conflictOf key.
        let legacy = """
        {"content":"x","priority":2,"status":0,"createdAt":1,"updatedAt":1}
        """
        let decoded = ConflictMerger.RecordFields.fromJSON(legacy)
        XCTAssertEqual(decoded?.content, "x")
        XCTAssertNil(decoded?.conflictOf)

        let withMarker = record(conflictOf: "orig").jsonString()
        XCTAssertEqual(ConflictMerger.RecordFields.fromJSON(withMarker)?.conflictOf, "orig")
    }

    func testProjectNameConflictNewerWins() {
        let ancestor = ConflictMerger.ProjectFields(name: "A", manualOrder: 0, createdAt: 1, updatedAt: 1)
        let local = ConflictMerger.ProjectFields(name: "Local", manualOrder: 0, createdAt: 1, updatedAt: 5)
        let server = ConflictMerger.ProjectFields(name: "Server", manualOrder: 2, createdAt: 1, updatedAt: 3)

        let merged = ConflictMerger.mergeProject(local: local, server: server, ancestor: ancestor)
        XCTAssertEqual(merged.name, "Local")
        XCTAssertEqual(merged.manualOrder, 2)
        XCTAssertEqual(merged.updatedAt, 5)
    }
}
