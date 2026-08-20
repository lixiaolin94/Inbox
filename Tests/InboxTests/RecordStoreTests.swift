import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class RecordStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-tests-\(UUID().uuidString)", isDirectory: true)
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
    private func createSync(_ content: String, projectID: String? = nil) throws -> Record {
        let expectation = expectation(description: "create")
        var result: Result<Record, Error>!
        store.createRecord(content: content, projectID: projectID) { r in
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

    private func updateSync(id: String, content: String) throws {
        let expectation = expectation(description: "update")
        var result: Result<Void, Error>!
        store.updateContent(id: id, content: content) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func updatePrioritySync(id: String, priority: Int) throws {
        let expectation = expectation(description: "updatePriority")
        var result: Result<Void, Error>!
        store.updatePriority(id: id, priority: priority) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func setStatusSync(id: String, status: RecordStatus) throws {
        let expectation = expectation(description: "setStatus")
        var result: Result<Void, Error>!
        store.setStatus(id: id, status: status) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func searchSync(
        _ term: String,
        scope: Scope = .all,
        sortOrder: RecordSort = .newestFirst,
        includeResolved: Bool = false
    ) throws -> [Record] {
        let expectation = expectation(description: "search")
        var result: Result<[Record], Error>!
        store.search(
            term: term,
            scope: scope,
            token: 0,
            sortOrder: sortOrder,
            includeResolved: includeResolved
        ) { r, _ in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    // MARK: - Schema / defaults

    func testCreateRecordDefaultsToOpenAndPriorityTwo() throws {
        let record = try createSync("first record")
        XCTAssertEqual(record.priority, 2)
        XCTAssertEqual(record.status, 0)
        XCTAssertNil(record.projectID)
        XCTAssertFalse(record.id.isEmpty)
        XCTAssertEqual(record.createdAt, record.updatedAt)
        XCTAssertNil(record.resolvedAt)
        XCTAssertNil(record.deletedAt)
    }

    func testDatabaseFileIsCreatedOnDisk() throws {
        try createSync("touch db")
        let dbPath = tempDirectory.appendingPathComponent("inbox-test.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - Listing / search

    func testEmptySearchTermReturnsAllOpenRecordsNewestFirst() throws {
        try createSync("first")
        try createSync("second")
        try createSync("third")
        let results = try searchSync("")
        XCTAssertEqual(results.map(\.content), ["third", "second", "first"])
    }

    func testSearchFindsEnglishSubstring() throws {
        try createSync("hello world")
        try createSync("goodbye")
        let results = try searchSync("hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "hello world")
    }

    func testSearchFindsChineseSubstringIncludingShortQueries() throws {
        // Regression guard: a plain FTS5 trigram MATCH requires >= 3
        // codepoints, and unicode61 doesn't tokenize CJK at all — both would
        // fail here. RecordStore's LIKE-based search must not.
        try createSync("你好世界")
        try createSync("早安,今天开会")

        let twoChar = try searchSync("世界")
        XCTAssertEqual(twoChar.count, 1)
        XCTAssertEqual(twoChar.first?.content, "你好世界")

        let oneChar = try searchSync("早")
        XCTAssertEqual(oneChar.count, 1)
        XCTAssertEqual(oneChar.first?.content, "早安,今天开会")

        let noMatch = try searchSync("下午")
        XCTAssertEqual(noMatch.count, 0)
    }

    func testSearchIsCaseAndWhitespaceTolerantOfEmptyAfterTrim() throws {
        try createSync("alpha")
        let results = try searchSync("   ")
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Update keeps FTS index consistent

    func testUpdateKeepsFTSIndexConsistent() throws {
        let record = try createSync("alpha content")
        try updateSync(id: record.id, content: "beta 测试内容")

        let oldTermResults = try searchSync("alpha")
        XCTAssertEqual(oldTermResults.count, 0)

        let newTermResults = try searchSync("beta")
        XCTAssertEqual(newTermResults.count, 1)
        XCTAssertEqual(newTermResults.first?.content, "beta 测试内容")

        let chineseResults = try searchSync("测试")
        XCTAssertEqual(chineseResults.count, 1)

        let ftsContent = try store.ftsContent(forRecordID: record.id)
        XCTAssertEqual(ftsContent, "beta 测试内容")
    }

    // MARK: - Priority persistence

    func testUpdatePriorityPersists() throws {
        let record = try createSync("adjust me")
        try updatePrioritySync(id: record.id, priority: Priority.p0.rawValue)

        let stored = try store.recordByID(record.id)
        XCTAssertEqual(stored?.priority, Priority.p0.rawValue)
        // Persistence must bump updated_at, never leave it stale.
        XCTAssertGreaterThanOrEqual(stored?.updatedAt ?? -1, record.updatedAt)
    }

    // MARK: - Resolve / Reopen persistence

    func testSetStatusResolvedRecordsResolvedAtAndDisappearsFromDefaultSearch() throws {
        let record = try createSync("finish me")
        try setStatusSync(id: record.id, status: .resolved)

        let stored = try store.recordByID(record.id)
        XCTAssertEqual(stored?.status, RecordStatus.resolved.rawValue)
        XCTAssertNotNil(stored?.resolvedAt)

        // search() only returns Open Records (Show Resolved defaults to Off).
        let openResults = try searchSync("")
        XCTAssertTrue(openResults.isEmpty)
    }

    func testSetStatusReopenClearsResolvedAtAndReturnsToOpenSearch() throws {
        let record = try createSync("finish then reopen")
        try setStatusSync(id: record.id, status: .resolved)
        try setStatusSync(id: record.id, status: .open)

        let stored = try store.recordByID(record.id)
        XCTAssertEqual(stored?.status, RecordStatus.open.rawValue)
        XCTAssertNil(stored?.resolvedAt)

        let openResults = try searchSync("")
        XCTAssertEqual(openResults.map(\.id), [record.id])
    }

    func testIncludeResolvedSearchReturnsOpenAndResolved() throws {
        let open = try createSync("still open")
        let resolved = try createSync("already done")
        try setStatusSync(id: resolved.id, status: .resolved)

        let hidden = try searchSync("")
        XCTAssertEqual(hidden.map(\.id), [open.id])

        let shown = try searchSync("", includeResolved: true)
        XCTAssertEqual(Set(shown.map(\.id)), [open.id, resolved.id])
        XCTAssertEqual(shown.first { $0.id == resolved.id }?.status, RecordStatus.resolved.rawValue)
    }

    func testIncludeResolvedSearchMatchesTermInResolvedRecords() throws {
        try createSync("open alpha")
        let resolved = try createSync("resolved alpha")
        try createSync("resolved beta")
        try setStatusSync(id: resolved.id, status: .resolved)

        XCTAssertEqual(try searchSync("alpha").map(\.content), ["open alpha"])
        XCTAssertEqual(
            Set(try searchSync("alpha", includeResolved: true).map(\.content)),
            ["open alpha", "resolved alpha"]
        )
    }

    func testOldestFirstSearchReturnsCreationOrder() throws {
        try createSync("first")
        try createSync("second")
        try createSync("third")
        let results = try searchSync("", sortOrder: .oldestFirst)
        XCTAssertEqual(results.map(\.content), ["first", "second", "third"])
    }

    func testPrioritySearchOrdersP0ToP3WithNewestFirstTieBreak() throws {
        let olderP1 = try createSync("older p1")
        let newerP1 = try createSync("newer p1")
        let p0 = try createSync("p0")
        let p3 = try createSync("p3")
        try updatePrioritySync(id: olderP1.id, priority: 1)
        try updatePrioritySync(id: newerP1.id, priority: 1)
        try updatePrioritySync(id: p0.id, priority: 0)
        try updatePrioritySync(id: p3.id, priority: 3)

        let results = try searchSync("", sortOrder: .priority)
        XCTAssertEqual(results.map(\.content), ["p0", "newer p1", "older p1", "p3"])
    }

    func testPrioritySearchTieBreakHoldsWhenIncludeResolved() throws {
        let olderP1 = try createSync("older p1")
        let resolvedP0 = try createSync("resolved p0")
        let newerP1 = try createSync("newer p1")
        try updatePrioritySync(id: olderP1.id, priority: 1)
        try updatePrioritySync(id: newerP1.id, priority: 1)
        try updatePrioritySync(id: resolvedP0.id, priority: 0)
        try setStatusSync(id: resolvedP0.id, status: .resolved)

        let results = try searchSync("", sortOrder: .priority, includeResolved: true)
        XCTAssertEqual(results.map(\.content), ["resolved p0", "newer p1", "older p1"])
    }

    // MARK: - Scope-filtered search (PRD §6.6)

    func testSearchScopeAllReturnsRecordsFromEveryProjectAndInbox() throws {
        let project = try createProjectSync("Work")
        try createSync("inbox item")
        try createSync("project item", projectID: project.id)

        let results = try searchSync("", scope: .all)
        XCTAssertEqual(Set(results.map(\.content)), ["inbox item", "project item"])
    }

    func testSearchScopeProjectOnlyReturnsThatProjectsRecords() throws {
        let project = try createProjectSync("Work")
        try createSync("inbox item")
        try createSync("project item", projectID: project.id)

        let results = try searchSync("", scope: .project(id: project.id))
        XCTAssertEqual(results.map(\.content), ["project item"])
    }

    func testSearchScopeProjectExcludesOtherProjectsAndInbox() throws {
        let projectA = try createProjectSync("A")
        let projectB = try createProjectSync("B")
        try createSync("in inbox")
        try createSync("in A", projectID: projectA.id)
        try createSync("in B", projectID: projectB.id)

        let resultsA = try searchSync("", scope: .project(id: projectA.id))
        XCTAssertEqual(resultsA.map(\.content), ["in A"])
    }

    func testSearchScopeCombinesWithSearchTerm() throws {
        let project = try createProjectSync("Work")
        try createSync("alpha in inbox")
        try createSync("alpha in project", projectID: project.id)
        try createSync("beta in project", projectID: project.id)

        let results = try searchSync("alpha", scope: .project(id: project.id))
        XCTAssertEqual(results.map(\.content), ["alpha in project"])
    }

    private func moveToTrashSync(id: String) throws {
        let expectation = expectation(description: "moveToTrash")
        var result: Result<Void, Error>!
        store.moveToTrash(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    @discardableResult
    private func restoreFromTrashSync(id: String) throws -> Record {
        let expectation = expectation(description: "restoreFromTrash")
        var result: Result<Record, Error>!
        store.restoreFromTrash(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func permanentlyDeleteSync(id: String) throws {
        let expectation = expectation(description: "permanentlyDelete")
        var result: Result<Void, Error>!
        store.permanentlyDelete(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func listTrashedSync() throws -> [Record] {
        let expectation = expectation(description: "listTrashed")
        var result: Result<[Record], Error>!
        store.listTrashed { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func updateProjectSync(id: String, projectID: String?) throws {
        let expectation = expectation(description: "updateProject")
        var result: Result<Void, Error>!
        store.updateProject(id: id, projectID: projectID) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    // MARK: - Move Project (PRD §8.7)

    func testUpdateProjectMovesRecordIntoProject() throws {
        let project = try createProjectSync("Work")
        let record = try createSync("inbox item")
        XCTAssertNil(record.projectID)

        try updateProjectSync(id: record.id, projectID: project.id)

        let stored = try store.recordByID(record.id)
        XCTAssertEqual(stored?.projectID, project.id)
        XCTAssertGreaterThanOrEqual(stored?.updatedAt ?? -1, record.updatedAt)

        let inProject = try searchSync("", scope: .project(id: project.id))
        XCTAssertEqual(inProject.map(\.id), [record.id])
    }

    func testUpdateProjectNilMovesRecordBackToInbox() throws {
        let project = try createProjectSync("Work")
        let record = try createSync("project item", projectID: project.id)

        try updateProjectSync(id: record.id, projectID: nil)

        let stored = try store.recordByID(record.id)
        XCTAssertNil(stored?.projectID)

        let inProject = try searchSync("", scope: .project(id: project.id))
        XCTAssertTrue(inProject.isEmpty)
        let inAll = try searchSync("", scope: .all)
        XCTAssertEqual(inAll.map(\.id), [record.id])
    }

    func testUpdateProjectCanMoveBetweenProjects() throws {
        let projectA = try createProjectSync("A")
        let projectB = try createProjectSync("B")
        let record = try createSync("item", projectID: projectA.id)

        try updateProjectSync(id: record.id, projectID: projectB.id)

        XCTAssertEqual(try store.recordByID(record.id)?.projectID, projectB.id)
        XCTAssertEqual(try searchSync("", scope: .project(id: projectA.id)), [])
        XCTAssertEqual(try searchSync("", scope: .project(id: projectB.id)).map(\.id), [record.id])
    }

    // MARK: - Schema migration (v1 -> v2)

    func testMigrationFromV1CreatesProjectTableAndPreservesExistingRecords() throws {
        let dbPath = tempDirectory.appendingPathComponent("migrate-v1.sqlite").path

        // Build a v1-only database by hand, mirroring the historical S1
        // schema literally (not by reusing RecordStore's current schema
        // constant) — this way the test keeps proving real upgrade behavior
        // even if that constant is later edited.
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
                """)
            try rawDB.run(
                """
                INSERT INTO record
                    (id, content, priority, status, project_id, created_at, updated_at, resolved_at, deleted_at)
                VALUES (?, ?, 2, 0, NULL, 1000, 1000, NULL, NULL)
                """,
                bindings: [.text("legacy-1"), .text("pre-migration record")]
            )
            try rawDB.run(
                "INSERT INTO record_fts (record_id, content) VALUES (?, ?)",
                bindings: [.text("legacy-1"), .text("pre-migration record")]
            )
            try rawDB.setUserVersion(1)
        }

        // Opening via RecordStore must run the v1 -> v2 migration in place.
        let migrated = try RecordStore(databasePath: dbPath)

        let stored = try migrated.recordByID("legacy-1")
        XCTAssertEqual(stored?.content, "pre-migration record")

        // project table exists and is empty (v1 had no Projects).
        let listExpectation = expectation(description: "listProjects")
        var projectsResult: Result<[Project], Error>!
        migrated.projects.listProjects { r in
            projectsResult = r
            listExpectation.fulfill()
        }
        wait(for: [listExpectation], timeout: 2)
        XCTAssertEqual(try projectsResult.get(), [])

        // The upgraded database is now usable end-to-end: new Records and
        // Projects can still be created after migration.
        let createExpectation = expectation(description: "create-after-migrate")
        var createResult: Result<Record, Error>!
        migrated.createRecord(content: "post-migration record", projectID: nil) { r in
            createResult = r
            createExpectation.fulfill()
        }
        wait(for: [createExpectation], timeout: 2)
        XCTAssertNoThrow(try createResult.get())
    }

    // MARK: - Soft delete / Restore / Permanent delete (PRD §8.8, §12)

    func testMoveToTrashThenRestoreOpenRoundTrip() throws {
        let record = try createSync("open item")
        XCTAssertEqual(record.status, RecordStatus.open.rawValue)
        XCTAssertNil(record.resolvedAt)
        XCTAssertNil(record.deletedAt)

        try moveToTrashSync(id: record.id)

        let trashed = try store.recordByID(record.id)
        XCTAssertEqual(trashed?.status, RecordStatus.trashed.rawValue)
        XCTAssertNotNil(trashed?.deletedAt)
        XCTAssertGreaterThanOrEqual(trashed?.updatedAt ?? -1, record.updatedAt)
        XCTAssertEqual(trashed?.deletedAt, trashed?.updatedAt)
        XCTAssertNil(trashed?.resolvedAt)
        XCTAssertEqual(trashed?.content, record.content)
        XCTAssertEqual(trashed?.priority, record.priority)
        XCTAssertEqual(trashed?.createdAt, record.createdAt)

        let restored = try restoreFromTrashSync(id: record.id)
        XCTAssertEqual(restored.status, RecordStatus.open.rawValue)
        XCTAssertNil(restored.deletedAt)
        XCTAssertNil(restored.resolvedAt)
        XCTAssertGreaterThanOrEqual(restored.updatedAt, trashed?.updatedAt ?? -1)
        XCTAssertEqual(restored.content, record.content)
        XCTAssertEqual(restored.priority, record.priority)
        XCTAssertEqual(restored.projectID, record.projectID)
        XCTAssertEqual(restored.createdAt, record.createdAt)
    }

    func testMoveToTrashThenRestoreResolvedRoundTrip() throws {
        let record = try createSync("resolved item")
        try setStatusSync(id: record.id, status: .resolved)
        let beforeTrash = try store.recordByID(record.id)
        XCTAssertEqual(beforeTrash?.status, RecordStatus.resolved.rawValue)
        let resolvedAt = beforeTrash?.resolvedAt
        XCTAssertNotNil(resolvedAt)

        try moveToTrashSync(id: record.id)

        let trashed = try store.recordByID(record.id)
        XCTAssertEqual(trashed?.status, RecordStatus.trashed.rawValue)
        XCTAssertEqual(trashed?.resolvedAt, resolvedAt, "resolved_at must survive trash (lossless restore)")
        XCTAssertNotNil(trashed?.deletedAt)

        let restored = try restoreFromTrashSync(id: record.id)
        XCTAssertEqual(restored.status, RecordStatus.resolved.rawValue)
        XCTAssertEqual(restored.resolvedAt, resolvedAt)
        XCTAssertNil(restored.deletedAt)
    }

    func testRestorePreservesProjectAndPriority() throws {
        let project = try createProjectSync("Work")
        let record = try createSync("keep fields", projectID: project.id)
        try updatePrioritySync(id: record.id, priority: Priority.p0.rawValue)

        try moveToTrashSync(id: record.id)
        let restored = try restoreFromTrashSync(id: record.id)

        XCTAssertEqual(restored.projectID, project.id)
        XCTAssertEqual(restored.priority, Priority.p0.rawValue)
        XCTAssertEqual(restored.content, "keep fields")
    }

    func testPermanentlyDeleteRemovesRecordAndFTSMirror() throws {
        let record = try createSync("gone forever")
        XCTAssertEqual(try store.ftsContent(forRecordID: record.id), "gone forever")

        try moveToTrashSync(id: record.id)
        try permanentlyDeleteSync(id: record.id)

        XCTAssertNil(try store.recordByID(record.id))
        XCTAssertNil(try store.ftsContent(forRecordID: record.id))
        XCTAssertTrue(try listTrashedSync().isEmpty)
        XCTAssertTrue(try searchSync("gone").isEmpty)
    }

    func testPermanentlyDeleteDoesNotTouchOpenOrResolvedRecords() throws {
        let open = try createSync("still open")
        let resolved = try createSync("still resolved")
        try setStatusSync(id: resolved.id, status: .resolved)

        try permanentlyDeleteSync(id: open.id)
        try permanentlyDeleteSync(id: resolved.id)

        XCTAssertEqual(try store.recordByID(open.id)?.status, RecordStatus.open.rawValue)
        XCTAssertEqual(try store.recordByID(resolved.id)?.status, RecordStatus.resolved.rawValue)
        XCTAssertEqual(try store.ftsContent(forRecordID: open.id), "still open")
    }

    func testListTrashedFiltersAndOrdersByDeletedAtDescending() throws {
        let open = try createSync("visible open")
        let resolved = try createSync("visible resolved")
        try setStatusSync(id: resolved.id, status: .resolved)

        let first = try createSync("trashed first")
        try moveToTrashSync(id: first.id)
        let firstDeletedAt = try store.recordByID(first.id)?.deletedAt ?? 0

        if firstDeletedAt == Int64(Date().timeIntervalSince1970 * 1000) {
            Thread.sleep(forTimeInterval: 0.002)
        }

        let second = try createSync("trashed second")
        try moveToTrashSync(id: second.id)

        let trashed = try listTrashedSync()
        XCTAssertEqual(Set(trashed.map(\.id)), [first.id, second.id])
        XCTAssertTrue(trashed.allSatisfy { $0.status == RecordStatus.trashed.rawValue })
        let deletedAts = trashed.compactMap(\.deletedAt)
        XCTAssertEqual(deletedAts, deletedAts.sorted(by: >))

        let shown = try searchSync("", includeResolved: true)
        XCTAssertEqual(Set(shown.map(\.id)), [open.id, resolved.id])
    }

    func testMainSearchNeverReturnsTrashedEvenWithShowResolved() throws {
        let open = try createSync("keep me")
        let resolved = try createSync("resolved keep")
        let doomed = try createSync("unique trash token xyzzy")
        try setStatusSync(id: resolved.id, status: .resolved)
        try moveToTrashSync(id: doomed.id)

        XCTAssertEqual(try searchSync("").map(\.id), [open.id])
        XCTAssertEqual(Set(try searchSync("", includeResolved: true).map(\.id)), [open.id, resolved.id])
        XCTAssertTrue(try searchSync("xyzzy").isEmpty)
        XCTAssertTrue(try searchSync("xyzzy", includeResolved: true).isEmpty)
    }

    func testMoveToTrashMissingIdFails() throws {
        XCTAssertThrowsError(try moveToTrashSync(id: "missing")) { error in
            XCTAssertEqual(error as? RecordStoreError, .notFound)
        }
    }

    func testRestoreFromTrashMissingIdFails() throws {
        XCTAssertThrowsError(try restoreFromTrashSync(id: "missing")) { error in
            XCTAssertEqual(error as? RecordStoreError, .notFound)
        }
    }

    func testRestoreAfterProjectDeleteReturnsRecordToInbox() throws {
        let project = try createProjectSync("Temporary")
        let record = try createSync("keep me", projectID: project.id)
        try moveToTrashSync(id: record.id)

        let deleteExpectation = expectation(description: "deleteProject")
        var deleteResult: Result<Void, Error>!
        store.projects.deleteProject(id: project.id) { r in
            deleteResult = r
            deleteExpectation.fulfill()
        }
        wait(for: [deleteExpectation], timeout: 2)
        try deleteResult.get()

        XCTAssertNil(try store.recordByID(record.id)?.projectID)

        let restored = try restoreFromTrashSync(id: record.id)
        XCTAssertNil(restored.projectID)
        XCTAssertEqual(restored.status, RecordStatus.open.rawValue)
        XCTAssertEqual(try searchSync("").map(\.id), [record.id])
    }

    func testRestoreOfNonTrashedRecordIsIdempotent() throws {
        let record = try createSync("already open")
        let restored = try restoreFromTrashSync(id: record.id)
        XCTAssertEqual(restored.status, RecordStatus.open.rawValue)
        XCTAssertEqual(restored.id, record.id)
        XCTAssertNil(restored.deletedAt)
    }
}
