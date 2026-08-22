import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class ExportTests: XCTestCase {
    private func sampleDocument() -> InboxExport.Document {
        let projects = [
            Project(id: "P1", name: "Work", manualOrder: 0, createdAt: 1_000, updatedAt: 1_000),
            Project(id: "P2", name: "家/生活", manualOrder: 1, createdAt: 2_000, updatedAt: 2_500)
        ]
        let records = [
            Record(
                id: "R1", content: "open one", priority: 2, status: RecordStatus.open.rawValue,
                projectID: "P1", createdAt: 10_000, updatedAt: 10_000, resolvedAt: nil, deletedAt: nil
            ),
            Record(
                id: "R2", content: "resolved one", priority: 0, status: RecordStatus.resolved.rawValue,
                projectID: nil, createdAt: 11_000, updatedAt: 12_000, resolvedAt: 12_000, deletedAt: nil
            ),
            Record(
                id: "R3", content: "他说“好”然后加了个 \" 引号", priority: 3, status: RecordStatus.trashed.rawValue,
                projectID: "P2", createdAt: 13_000, updatedAt: 14_000, resolvedAt: nil, deletedAt: 14_000
            )
        ]
        return InboxExport.Document(
            projects: projects,
            records: records,
            schemaVersion: 3,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testKeysAreSchemaColumnNames() throws {
        let data = try InboxExport.encode(sampleDocument())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        for key in ["project_id", "created_at", "updated_at", "resolved_at", "deleted_at", "manual_order",
                    "format_version", "exported_at", "exported_at_iso8601", "schema_version", "app"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
        for camel in ["projectID", "createdAt", "manualOrder", "formatVersion"] {
            XCTAssertFalse(json.contains("\"\(camel)\""), "camelCase key leaked: \(camel)")
        }
        // Nil optionals are explicit nulls so every Record has all nine columns.
        XCTAssertTrue(json.contains("\"project_id\" : null"))
        XCTAssertTrue(json.contains("\"resolved_at\" : null"))
        // CJK stays readable; the embedded quote is escaped; slashes are not.
        XCTAssertTrue(json.contains("他说“好”然后加了个 \\\" 引号"))
        XCTAssertTrue(json.contains("家/生活"))
        XCTAssertFalse(json.contains("\\/"))
        XCTAssertTrue(json.contains("\"format_version\" : 1"))
        XCTAssertTrue(json.contains("\"exported_at_iso8601\" : \"2023-11-14T22:13:20Z\""))
    }

    func testRoundTripKeepsEveryRecordIncludingTrashed() throws {
        let document = sampleDocument()
        let data = try InboxExport.encode(document)
        let decoded = try InboxExport.decode(data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.records.count, 3)
        XCTAssertEqual(decoded.records.filter { $0.status == RecordStatus.trashed.rawValue }.count, 1)
        XCTAssertEqual(decoded.projects.map(\.id), ["P1", "P2"])
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.exportedAt, 1_700_000_000_000)
    }
}
