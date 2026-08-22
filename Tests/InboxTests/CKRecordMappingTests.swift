import XCTest
#if SWIFT_PACKAGE
@testable import Inbox

// SPM-only: the Xcode InboxTests target does not compile
// Sync/CKRecordMapping.swift (it lists logic sources explicitly).
final class CKRecordMappingTests: XCTestCase {
    private func record(conflictOf: String?) -> Record {
        Record(
            id: "local-1",
            content: "round trip",
            priority: 1,
            status: 0,
            projectID: "proj-1",
            createdAt: 100,
            updatedAt: 200,
            resolvedAt: nil,
            deletedAt: nil,
            conflictOf: conflictOf
        )
    }

    func testRecordRoundTripWithoutConflictMarker() {
        let ckRecord = CKRecordMapping.makeRecord(from: record(conflictOf: nil), metadata: nil)
        XCTAssertNil(ckRecord["conflictOf"])

        let fields = CKRecordMapping.recordFields(from: ckRecord)
        XCTAssertEqual(fields, ConflictMerger.RecordFields(record(conflictOf: nil)))
        XCTAssertNil(fields.conflictOf)
    }

    func testRecordRoundTripWithConflictMarker() {
        let ckRecord = CKRecordMapping.makeRecord(from: record(conflictOf: "orig-1"), metadata: nil)
        XCTAssertEqual(ckRecord["conflictOf"] as? String, "orig-1")

        let fields = CKRecordMapping.recordFields(from: ckRecord)
        XCTAssertEqual(fields, ConflictMerger.RecordFields(record(conflictOf: "orig-1")))
        XCTAssertEqual(fields.conflictOf, "orig-1")
    }
}
#endif
