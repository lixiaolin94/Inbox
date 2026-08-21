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
        deletedAt: Int64? = nil
    ) -> ConflictMerger.RecordFields {
        ConflictMerger.RecordFields(
            content: content,
            priority: priority,
            status: status,
            projectID: projectID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            resolvedAt: resolvedAt,
            deletedAt: deletedAt
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
