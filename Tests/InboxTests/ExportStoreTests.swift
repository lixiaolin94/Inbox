import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class ExportStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let dbPath = tempDirectory.appendingPathComponent("inbox-test.sqlite").path
        store = try RecordStore(databasePath: dbPath)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Helpers

    @discardableResult
    private func createSync(_ store: RecordStore, _ content: String) throws -> Record {
        let expectation = expectation(description: "create")
        var result: Result<Record, Error>!
        store.createRecord(content: content) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func trashSync(id: String) throws {
        let expectation = expectation(description: "trash")
        var result: Result<Void, Error>!
        store.moveToTrash(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func listAllSync(_ store: RecordStore) throws -> [Record] {
        let expectation = expectation(description: "listAll")
        var result: Result<[Record], Error>!
        store.listAllRecordsForExport { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func snapshotSync(to url: URL) throws {
        let expectation = expectation(description: "snapshot")
        var result: Result<Void, Error>!
        store.writeSnapshot(to: url) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    // MARK: - Tests

    func testDatabasePathIsTheOpenedFile() {
        XCTAssertEqual(store.databasePath, tempDirectory.appendingPathComponent("inbox-test.sqlite").path)
    }

    func testSchemaVersionIsCurrent() throws {
        XCTAssertEqual(try store.currentSchemaVersion(), 4)
    }

    func testListAllIncludesTrashedOldestFirst() throws {
        let a = try createSync(store, "a")
        let b = try createSync(store, "b")
        let c = try createSync(store, "c")
        try trashSync(id: b.id)

        let all = try listAllSync(store)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.id)), [a.id, b.id, c.id])
        XCTAssertEqual(all.map(\.createdAt), all.map(\.createdAt).sorted())
        XCTAssertEqual(all.first { $0.id == b.id }?.status, RecordStatus.trashed.rawValue)
    }

    func testSnapshotIsStandaloneAndComplete() throws {
        let a = try createSync(store, "a")
        try createSync(store, "b")
        try createSync(store, "c")
        try trashSync(id: a.id)

        let snapshotURL = tempDirectory.appendingPathComponent("snapshot.sqlite")
        // Pre-existing target: VACUUM INTO refuses to overwrite, the store must clear it.
        try Data("stale".utf8).write(to: snapshotURL)
        try snapshotSync(to: snapshotURL)

        // Standalone: no -wal/-shm sidecars next to the snapshot before it's opened.
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))

        let copy = try RecordStore(databasePath: snapshotURL.path)
        let copied = try listAllSync(copy)
        XCTAssertEqual(copied.count, 3)
        XCTAssertEqual(copied.first { $0.id == a.id }?.status, RecordStatus.trashed.rawValue)
        XCTAssertEqual(try copy.currentSchemaVersion(), 4)

        // The original keeps working after the VACUUM.
        try createSync(store, "d")
        XCTAssertEqual(try listAllSync(store).count, 4)
        XCTAssertEqual(try listAllSync(copy).count, 3)
    }
}
