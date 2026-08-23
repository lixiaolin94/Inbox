import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class SyncTrackingTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let dbPath = tempDirectory.appendingPathComponent("inbox-test.sqlite").path
        store = try RecordStore(databasePath: dbPath)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: tempDirectory)
    }

    @discardableResult
    private func createSync(_ content: String) throws -> Record {
        let expectation = expectation(description: "create")
        var result: Result<Record, Error>!
        store.createRecord(content: content, projectID: nil) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    @discardableResult
    private func createProjectSync(_ name: String) throws -> Project {
        let expectation = expectation(description: "createProject")
        var result: Result<Project, Error>!
        store.projects.createProject(name: name) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func moveToTrashSync(id: String) throws {
        let expectation = expectation(description: "trash")
        var result: Result<Void, Error>!
        store.moveToTrash(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func permanentlyDeleteSync(id: String) throws {
        let expectation = expectation(description: "delete")
        var result: Result<Void, Error>!
        store.permanentlyDelete(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    // MARK: - Schema v3 / v4

    func testFreshDatabaseIsUserVersion4() throws {
        XCTAssertEqual(try store.userVersion(), 4)
    }

    func testMigrationFromV2AddsSyncTablesAndPreservesRows() throws {
        let dbPath = tempDirectory.appendingPathComponent("migrate-v2.sqlite").path
        do {
            let rawDB = try SQLiteDatabase(path: dbPath)
            try rawDB.exec("""
                CREATE TABLE record (
                    id TEXT PRIMARY KEY,
                    content TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 2,
                    status INTEGER NOT NULL DEFAULT 0,
                    project_id TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    resolved_at INTEGER,
                    deleted_at INTEGER
                );
                CREATE INDEX idx_record_status_created ON record(status, created_at DESC);
                CREATE VIRTUAL TABLE record_fts USING fts5(
                    record_id UNINDEXED,
                    content,
                    tokenize = 'trigram'
                );
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    manual_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """)
            try rawDB.run(
                """
                INSERT INTO record
                    (id, content, priority, status, project_id, created_at, updated_at, resolved_at, deleted_at)
                VALUES (?, ?, 2, 0, NULL, 1000, 1000, NULL, NULL)
                """,
                bindings: [.text("legacy-2"), .text("v2 record")]
            )
            try rawDB.run(
                "INSERT INTO record_fts (record_id, content) VALUES (?, ?)",
                bindings: [.text("legacy-2"), .text("v2 record")]
            )
            try rawDB.run(
                "INSERT INTO project (id, name, manual_order, created_at, updated_at) VALUES (?, ?, 0, 1, 1)",
                bindings: [.text("proj-1"), .text("Work")]
            )
            try rawDB.setUserVersion(2)
        }

        let migrated = try RecordStore(databasePath: dbPath)
        XCTAssertEqual(try migrated.userVersion(), 4)
        XCTAssertEqual(try migrated.recordByID("legacy-2")?.content, "v2 record")

        let pending = try migrated.pendingChanges()
        XCTAssertTrue(pending.contains { $0.entity == .record && $0.id == "legacy-2" && $0.changeType == .upsert })
        XCTAssertTrue(pending.contains { $0.entity == .project && $0.id == "proj-1" && $0.changeType == .upsert })
        XCTAssertNil(try migrated.ckSystemFields(entity: .record, id: "legacy-2"))
    }

    func testMigrationFromV3AddsConflictOfAndPreservesRows() throws {
        let dbPath = tempDirectory.appendingPathComponent("migrate-v3.sqlite").path
        do {
            // Literal v3 schema (v1 + v2 + v3 DDL), not RecordStore's constants,
            // so the test keeps proving the real upgrade path.
            let rawDB = try SQLiteDatabase(path: dbPath)
            try rawDB.exec("""
                CREATE TABLE record (
                    id TEXT PRIMARY KEY,
                    content TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 2,
                    status INTEGER NOT NULL DEFAULT 0,
                    project_id TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    resolved_at INTEGER,
                    deleted_at INTEGER,
                    ck_system_fields BLOB
                );
                CREATE INDEX idx_record_status_created ON record(status, created_at DESC);
                CREATE VIRTUAL TABLE record_fts USING fts5(
                    record_id UNINDEXED,
                    content,
                    tokenize = 'trigram'
                );
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    manual_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    ck_system_fields BLOB
                );
                CREATE TABLE pending_change (
                    entity TEXT NOT NULL,
                    id TEXT NOT NULL,
                    change_type TEXT NOT NULL,
                    PRIMARY KEY (entity, id)
                );
                CREATE TABLE tombstone (
                    entity TEXT NOT NULL,
                    id TEXT NOT NULL,
                    deleted_at INTEGER NOT NULL,
                    PRIMARY KEY (entity, id)
                );
                """)
            try rawDB.run(
                """
                INSERT INTO record
                    (id, content, priority, status, project_id, created_at, updated_at,
                     resolved_at, deleted_at, ck_system_fields)
                VALUES (?, ?, 1, 1, NULL, 1000, 2000, 2000, NULL, ?)
                """,
                bindings: [.text("legacy-3"), .text("v3 record"), .blob(Data([0x01]))]
            )
            try rawDB.run(
                "INSERT INTO record_fts (record_id, content) VALUES (?, ?)",
                bindings: [.text("legacy-3"), .text("v3 record")]
            )
            try rawDB.setUserVersion(3)
        }

        let migrated = try RecordStore(databasePath: dbPath)
        XCTAssertEqual(try migrated.userVersion(), 4)
        let stored = try migrated.recordByID("legacy-3")
        XCTAssertEqual(stored?.content, "v3 record")
        XCTAssertEqual(stored?.priority, 1)
        XCTAssertEqual(stored?.status, 1)
        XCTAssertEqual(stored?.resolvedAt, 2000)
        XCTAssertNil(stored?.conflictOf)
        XCTAssertEqual(try migrated.ckSystemFields(entity: .record, id: "legacy-3"), Data([0x01]))
        // v3 -> v4 is column-only: no pending upsert is manufactured for old rows.
        XCTAssertTrue(try migrated.pendingChanges().isEmpty)
    }

    // MARK: - Pending / tombstone

    func testCreateRecordRegistersPendingUpsert() throws {
        let record = try createSync("to upload")
        let pending = try store.pendingChanges()
        XCTAssertEqual(pending, [PendingChange(entity: .record, id: record.id, changeType: .upsert)])
    }

    func testCreateProjectRegistersPendingUpsert() throws {
        let project = try createProjectSync("Work")
        let pending = try store.pendingChanges()
        XCTAssertTrue(pending.contains { $0.entity == .project && $0.id == project.id && $0.changeType == .upsert })
    }

    func testPermanentDeleteWritesTombstoneAndPendingDelete() throws {
        let record = try createSync("gone")
        try moveToTrashSync(id: record.id)
        try permanentlyDeleteSync(id: record.id)

        XCTAssertNil(try store.recordByID(record.id))
        let tombstones = try store.tombstones()
        XCTAssertEqual(tombstones.map(\.id), [record.id])
        let pending = try store.pendingChanges()
        XCTAssertEqual(
            pending.first { $0.id == record.id }?.changeType,
            .delete
        )
    }

    func testAcknowledgeDeletionClearsTombstoneAndPending() throws {
        let record = try createSync("gone")
        try moveToTrashSync(id: record.id)
        try permanentlyDeleteSync(id: record.id)
        try store.acknowledgeDeletion(entity: .record, id: record.id)

        XCTAssertTrue(try store.tombstones().isEmpty)
        XCTAssertFalse(try store.pendingChanges().contains { $0.id == record.id })
    }

    func testOnDidCommitChangeFiresAfterCreate() throws {
        let expectation = expectation(description: "callback")
        var received: [PendingChange] = []
        store.onDidCommitChange = { changes in
            received = changes
            // Fired on the DB queue; hop out so the test waiter is not the queue.
            DispatchQueue.main.async { expectation.fulfill() }
        }
        let record = try createSync("callback")
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received, [PendingChange(entity: .record, id: record.id, changeType: .upsert)])
    }

    // MARK: - Remote apply / delete vs edit

    func testRemoteDeletionRetainsUnsyncedLocalEdit() throws {
        let record = try createSync("keep me")
        let result = try store.applyRemoteDeletion(entity: .record, id: record.id)
        XCTAssertEqual(result, .retainedNeedsUpload)
        XCTAssertEqual(try store.recordByID(record.id)?.content, "keep me")
    }

    func testRemoteDeletionRemovesSyncedRecord() throws {
        let record = try createSync("synced")
        let metadata = CKLocalMetadata.pack(systemFields: Data([0x01, 0x02]), ancestorJSON: "{}")
        try store.acknowledgeUpload(entity: .record, id: record.id, metadata: metadata)

        let result = try store.applyRemoteDeletion(entity: .record, id: record.id)
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(try store.recordByID(record.id))
    }

    func testRequeueAllForSyncForgetsServerStateAndQueuesEveryRow() throws {
        let payload = ConflictMerger.RecordFields(
            content: "synced", priority: 2, status: 0, projectID: nil,
            createdAt: 10, updatedAt: 10, resolvedAt: nil, deletedAt: nil
        )
        _ = try store.applyFetchedRecord(id: "synced-1", payload: payload, metadata: Data([0x01]))
        let local = try createSync("local only")
        XCTAssertNotNil(try store.ckSystemFields(entity: .record, id: "synced-1"))

        try store.requeueAllForSync()

        XCTAssertNil(try store.ckSystemFields(entity: .record, id: "synced-1"))
        let pending = try store.pendingChanges().filter { $0.entity == .record }
        XCTAssertEqual(Set(pending.map(\.id)), ["synced-1", local.id])
        XCTAssertTrue(pending.allSatisfy { $0.changeType == .upsert })
        XCTAssertEqual(try store.recordByID("synced-1")?.content, "synced", "local rows untouched")
    }

    func testApplyFetchedRecordInsertsNewRow() throws {
        let payload = ConflictMerger.RecordFields(
            content: "from server",
            priority: 1,
            status: 0,
            projectID: nil,
            createdAt: 10,
            updatedAt: 10,
            resolvedAt: nil,
            deletedAt: nil
        )
        let result = try store.applyFetchedRecord(id: "remote-1", payload: payload, metadata: nil)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(try store.recordByID("remote-1")?.content, "from server")
        XCTAssertFalse(try store.pendingChanges().contains { $0.id == "remote-1" })
    }

    func testApplyFetchedRecordMergesUnsyncedLocalPriority() throws {
        let local = try createSync("same")
        let ancestor = ConflictMerger.RecordFields(local)
        let metadata = CKLocalMetadata.pack(
            systemFields: Data([0x01]),
            ancestorJSON: ancestor.jsonString()
        )
        try store.acknowledgeUpload(entity: .record, id: local.id, metadata: metadata)
        try updatePrioritySync(id: local.id, priority: 0)

        let payload = ConflictMerger.RecordFields(
            content: "same",
            priority: 2,
            status: 1,
            projectID: nil,
            createdAt: local.createdAt,
            updatedAt: local.updatedAt,
            resolvedAt: 5,
            deletedAt: nil
        )
        let result = try store.applyFetchedRecord(id: local.id, payload: payload, metadata: nil)
        XCTAssertEqual(result, .appliedNeedsUpload(id: local.id))
        let stored = try store.recordByID(local.id)
        XCTAssertEqual(stored?.priority, 0)
        XCTAssertEqual(stored?.status, 1)
        XCTAssertEqual(stored?.resolvedAt, 5)
    }

    func testApplyFetchedRecordContentConflictInsertsDuplicate() throws {
        let local = try createSync("local content")
        let payload = ConflictMerger.RecordFields(
            content: "server content",
            priority: 2,
            status: 0,
            projectID: nil,
            createdAt: local.createdAt,
            updatedAt: local.updatedAt,
            resolvedAt: nil,
            deletedAt: nil
        )
        let result = try store.applyFetchedRecord(id: local.id, payload: payload, metadata: nil)
        guard case .keepBothNeedsUpload(let originalID, let duplicateID) = result else {
            return XCTFail("expected keepBoth, got \(result)")
        }
        XCTAssertEqual(originalID, local.id)
        XCTAssertEqual(try store.recordByID(local.id)?.content, "server content")
        XCTAssertEqual(try store.recordByID(duplicateID)?.content, "local content")
        XCTAssertNotEqual(duplicateID, local.id)

        // The duplicate is the marked half of the pair; the original is not.
        XCTAssertEqual(try store.recordByID(duplicateID)?.conflictOf, local.id)
        XCTAssertNil(try store.recordByID(local.id)?.conflictOf)
        // It uploads with the marker so the other device sees the pair too.
        XCTAssertTrue(try store.pendingChanges().contains { $0.id == duplicateID && $0.changeType == .upsert })
        XCTAssertEqual(try store.loadRecordForUpload(id: duplicateID)?.0.conflictOf, local.id)
    }

    func testApplyFetchedRecordStoresRemoteConflictMarker() throws {
        var payload = ConflictMerger.RecordFields(
            content: "their duplicate",
            priority: 2,
            status: 0,
            projectID: nil,
            createdAt: 10,
            updatedAt: 10,
            resolvedAt: nil,
            deletedAt: nil
        )
        payload.conflictOf = "remote-orig"
        XCTAssertEqual(try store.applyFetchedRecord(id: "remote-dup", payload: payload, metadata: nil), .applied)
        XCTAssertEqual(try store.recordByID("remote-dup")?.conflictOf, "remote-orig")

        // A later fetch that clears the marker (resolved elsewhere) clears it here.
        payload.conflictOf = nil
        payload.updatedAt = 20
        XCTAssertEqual(try store.applyFetchedRecord(id: "remote-dup", payload: payload, metadata: nil), .applied)
        XCTAssertNil(try store.recordByID("remote-dup")?.conflictOf)
    }

    func testMetadataEnvelopeRoundTrip() {
        let packed = CKLocalMetadata.pack(systemFields: Data([0xAA, 0xBB]), ancestorJSON: "{\"content\":\"x\"}")
        let unpacked = CKLocalMetadata.unpack(packed)
        XCTAssertEqual(unpacked?.systemFields, Data([0xAA, 0xBB]))
        XCTAssertEqual(unpacked?.ancestorJSON, "{\"content\":\"x\"}")
    }

    private func updatePrioritySync(id: String, priority: Int) throws {
        let expectation = expectation(description: "priority")
        var result: Result<Void, Error>!
        store.updatePriority(id: id, priority: priority) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }
}
