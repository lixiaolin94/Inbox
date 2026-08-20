import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class RecordSortTests: XCTestCase {

    private func record(
        _ id: String,
        priority: Int = 2,
        createdAt: Int64
    ) -> Record {
        Record(
            id: id,
            content: id,
            priority: priority,
            status: 0,
            projectID: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            resolvedAt: nil,
            deletedAt: nil
        )
    }

    func testNewestFirstOrdersByCreatedAtDescending() {
        let a = record("a", createdAt: 100)
        let b = record("b", createdAt: 300)
        let c = record("c", createdAt: 200)
        XCTAssertEqual(RecordSort.newestFirst.sorted([a, b, c]).map(\.id), ["b", "c", "a"])
    }

    func testOldestFirstOrdersByCreatedAtAscending() {
        let a = record("a", createdAt: 100)
        let b = record("b", createdAt: 300)
        let c = record("c", createdAt: 200)
        XCTAssertEqual(RecordSort.oldestFirst.sorted([a, b, c]).map(\.id), ["a", "c", "b"])
    }

    func testPriorityOrdersP0ToP3() {
        let p3 = record("p3", priority: 3, createdAt: 400)
        let p0 = record("p0", priority: 0, createdAt: 100)
        let p2 = record("p2", priority: 2, createdAt: 200)
        let p1 = record("p1", priority: 1, createdAt: 300)
        XCTAssertEqual(
            RecordSort.priority.sorted([p3, p0, p2, p1]).map(\.id),
            ["p0", "p1", "p2", "p3"]
        )
    }

    func testPriorityTieBreaksWithNewestFirst() {
        let olderP1 = record("older", priority: 1, createdAt: 100)
        let newerP1 = record("newer", priority: 1, createdAt: 200)
        let p0 = record("p0", priority: 0, createdAt: 50)
        XCTAssertEqual(
            RecordSort.priority.sorted([olderP1, newerP1, p0]).map(\.id),
            ["p0", "newer", "older"]
        )
    }

    func testEqualCreatedAtKeepsOriginalOrder() {
        let a = record("a", priority: 1, createdAt: 100)
        let b = record("b", priority: 1, createdAt: 100)
        XCTAssertEqual(RecordSort.newestFirst.sorted([a, b]).map(\.id), ["a", "b"])
        XCTAssertEqual(RecordSort.oldestFirst.sorted([b, a]).map(\.id), ["b", "a"])
        XCTAssertEqual(RecordSort.priority.sorted([a, b]).map(\.id), ["a", "b"])
    }
}
