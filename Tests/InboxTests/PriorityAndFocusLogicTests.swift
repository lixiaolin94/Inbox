import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

/// Pure-logic tests (no store, no DB): Priority boundary rules (PRD §8.4) and
/// the Row Focus inheritance rule (PRD §8.6). Per SPEC's test strategy these
/// are the two "纯逻辑" cases carved out of Slice S2.
final class PriorityAndFocusLogicTests: XCTestCase {

    // MARK: - Priority boundary (←/→)

    func testRaiseMovesTowardP0() {
        XCTAssertEqual(Priority.p3.raised, .p2)
        XCTAssertEqual(Priority.p2.raised, .p1)
        XCTAssertEqual(Priority.p1.raised, .p0)
    }

    func testRaiseAtP0DoesNotCycle() {
        XCTAssertEqual(Priority.p0.raised, .p0)
    }

    func testLowerMovesTowardP3() {
        XCTAssertEqual(Priority.p0.lowered, .p1)
        XCTAssertEqual(Priority.p1.lowered, .p2)
        XCTAssertEqual(Priority.p2.lowered, .p3)
    }

    func testLowerAtP3DoesNotCycle() {
        XCTAssertEqual(Priority.p3.lowered, .p3)
    }

    func testPriorityAdjustmentApply() {
        XCTAssertEqual(PriorityAdjustment.raise.apply(to: .p2), .p1)
        XCTAssertEqual(PriorityAdjustment.lower.apply(to: .p2), .p3)
    }

    // MARK: - Row Focus inheritance (Resolve / Space)

    func testFocusInheritsNextRecordAtSameIndex() {
        // 4 rows, removed index 1 -> 3 remain, the row that used to be at
        // index 2 now occupies index 1.
        let next = RowFocusInheritance.nextFocusIndex(afterRemovingRowAt: 1, remainingCount: 3)
        XCTAssertEqual(next, 1)
    }

    func testFocusFallsBackToPreviousWhenRemovedRowWasLast() {
        // 3 rows, removed the last one (index 2) -> 2 remain, no row now
        // occupies index 2, so focus falls back to the new last row.
        let next = RowFocusInheritance.nextFocusIndex(afterRemovingRowAt: 2, remainingCount: 2)
        XCTAssertEqual(next, 1)
    }

    func testFocusReturnsToInputWhenListBecomesEmpty() {
        let next = RowFocusInheritance.nextFocusIndex(afterRemovingRowAt: 0, remainingCount: 0)
        XCTAssertNil(next)
    }

    // MARK: - Show Resolved On: stay on the Open stream (PRD §8.6)

    func testResolveWithShowResolvedOnFocusesNextOpenRecord() {
        let next = RowFocusInheritance.nextOpenRecordID(
            afterResolving: "b",
            previousOpenIDs: ["a", "b", "c"],
            remainingOpenIDs: ["a", "c"]
        )
        XCTAssertEqual(next, "c")
    }

    func testResolveLastOpenFallsBackToPreviousOpen() {
        let next = RowFocusInheritance.nextOpenRecordID(
            afterResolving: "b",
            previousOpenIDs: ["a", "b"],
            remainingOpenIDs: ["a"]
        )
        XCTAssertEqual(next, "a")
    }

    func testResolveLastRemainingOpenReturnsToInput() {
        let next = RowFocusInheritance.nextOpenRecordID(
            afterResolving: "only",
            previousOpenIDs: ["only"],
            remainingOpenIDs: []
        )
        XCTAssertNil(next)
    }

    func testResolveIgnoresResolvedIdsWhenPickingNextOpen() {
        // Remaining visible list still has resolved rows; Open sequence does not.
        let next = RowFocusInheritance.nextOpenRecordID(
            afterResolving: "a",
            previousOpenIDs: ["a", "b"],
            remainingOpenIDs: ["b"]
        )
        XCTAssertEqual(next, "b")
    }
}
