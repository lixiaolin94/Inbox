import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

/// Conflict pairs (PRD §15.3): listing, the conflicts-only search filter
/// and the three lossless resolutions.
final class ConflictPairTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-conflict-tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Builds a real Keep Both pair through the sync apply path: unsynced
    /// local content meets a fetched server content for the same id.
    private func makeConflictPair(
        local: String = "local edit",
        server: String = "server edit",
        projectID: String? = nil
    ) throws -> (original: Record, duplicate: Record) {
        let created = try createSync(local, projectID: projectID)
        let payload = ConflictMerger.RecordFields(
            content: server,
            priority: 2,
            status: 0,
            projectID: projectID,
            createdAt: created.createdAt,
            updatedAt: created.updatedAt,
            resolvedAt: nil,
            deletedAt: nil
        )
        let result = try store.applyFetchedRecord(id: created.id, payload: payload, metadata: nil)
        guard case .keepBothNeedsUpload(let originalID, let duplicateID) = result,
              let original = try store.recordByID(originalID),
              let duplicate = try store.recordByID(duplicateID) else {
            XCTFail("expected keepBoth, got \(result)")
            throw RecordStoreError.notFound
        }
        return (original, duplicate)
    }

    private func listConflictsSync() throws -> [Record] {
        let expectation = expectation(description: "listConflicts")
        var result: Result<[Record], Error>!
        store.listConflicts { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func searchSync(
        _ term: String = "",
        scope: Scope = .all,
        includeResolved: Bool = false,
        onlyConflicts: Bool = false
    ) throws -> [Record] {
        let expectation = expectation(description: "search")
        var result: Result<[Record], Error>!
        store.search(
            term: term,
            scope: scope,
            token: 0,
            includeResolved: includeResolved,
            onlyConflicts: onlyConflicts
        ) { r, _ in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func resolveSync(id: String, _ resolution: ConflictResolution) throws {
        let expectation = expectation(description: "resolve")
        var result: Result<Void, Error>!
        store.resolveConflict(id: id, resolution: resolution) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
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

    @discardableResult
    private func restoreFromTrashSync(id: String) throws -> Record {
        let expectation = expectation(description: "restore")
        var result: Result<Record, Error>!
        store.restoreFromTrash(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    private func assertTrashed(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try store.recordByID(id)
        XCTAssertEqual(row?.status, RecordStatus.trashed.rawValue, file: file, line: line)
        XCTAssertNotNil(row?.deletedAt, file: file, line: line)
        XCTAssertNil(row?.conflictOf, file: file, line: line)
    }

    private func assertOpenAndUnmarked(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try store.recordByID(id)
        XCTAssertEqual(row?.status, RecordStatus.open.rawValue, file: file, line: line)
        XCTAssertNil(row?.deletedAt, file: file, line: line)
        XCTAssertNil(row?.conflictOf, file: file, line: line)
    }

    // MARK: - Listing and filter

    func testListConflictsReturnsOnlyMarkedDuplicates() throws {
        XCTAssertTrue(try listConflictsSync().isEmpty)
        try createSync("unrelated")
        let first = try makeConflictPair(local: "a local", server: "a server")
        let second = try makeConflictPair(local: "b local", server: "b server")

        let conflicts = try listConflictsSync()
        XCTAssertEqual(Set(conflicts.map(\.id)), [first.duplicate.id, second.duplicate.id])
        XCTAssertTrue(conflicts.allSatisfy { $0.conflictOf != nil })
        let createdAts = conflicts.map(\.createdAt)
        XCTAssertEqual(createdAts, createdAts.sorted(by: >))
    }

    func testListConflictsExcludesTrashedDuplicates() throws {
        let pair = try makeConflictPair()
        try moveToTrashSync(id: pair.duplicate.id)
        XCTAssertTrue(try listConflictsSync().isEmpty)
    }

    func testSearchOnlyConflictsReturnsBothMembersOfEachPair() throws {
        let unrelated = try createSync("unrelated alpha")
        let pair = try makeConflictPair(local: "alpha local", server: "alpha server")

        XCTAssertEqual(
            Set(try searchSync().map(\.id)),
            [unrelated.id, pair.original.id, pair.duplicate.id]
        )
        XCTAssertEqual(
            Set(try searchSync(onlyConflicts: true).map(\.id)),
            [pair.original.id, pair.duplicate.id]
        )
        // The other clauses still apply on top of the filter.
        XCTAssertEqual(try searchSync("server", onlyConflicts: true).map(\.id), [pair.original.id])
        XCTAssertTrue(try searchSync("unrelated", onlyConflicts: true).isEmpty)
    }

    func testSearchOnlyConflictsRespectsScope() throws {
        let project = try createProjectSync("Work")
        let inProject = try makeConflictPair(local: "p local", server: "p server", projectID: project.id)
        try makeConflictPair(local: "inbox local", server: "inbox server")

        XCTAssertEqual(
            Set(try searchSync(scope: .project(id: project.id), onlyConflicts: true).map(\.id)),
            [inProject.original.id, inProject.duplicate.id]
        )
    }

    // MARK: - Resolutions

    func testKeepThisOnDuplicateTrashesOriginalAndClearsMarker() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.duplicate.id, .keepThis)

        try assertOpenAndUnmarked(pair.duplicate.id)
        try assertTrashed(pair.original.id)
        XCTAssertEqual(try store.recordByID(pair.original.id)?.content, "server edit")
        XCTAssertTrue(try listConflictsSync().isEmpty)
        XCTAssertEqual(try searchSync().map(\.id), [pair.duplicate.id])

        // Both rows changed, both sync.
        let pending = try store.pendingChanges().filter { $0.changeType == .upsert }.map(\.id)
        XCTAssertEqual(Set(pending), [pair.original.id, pair.duplicate.id])
        XCTAssertGreaterThanOrEqual(try store.recordByID(pair.duplicate.id)?.updatedAt ?? -1, pair.duplicate.updatedAt)
    }

    func testKeepThisOnOriginalTrashesDuplicate() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.original.id, .keepThis)

        try assertOpenAndUnmarked(pair.original.id)
        try assertTrashed(pair.duplicate.id)
        XCTAssertTrue(try listConflictsSync().isEmpty)
        XCTAssertEqual(try searchSync().map(\.id), [pair.original.id])
    }

    func testKeepOtherOnDuplicateTrashesDuplicate() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.duplicate.id, .keepOther)

        try assertTrashed(pair.duplicate.id)
        try assertOpenAndUnmarked(pair.original.id)
        XCTAssertTrue(try listConflictsSync().isEmpty)
    }

    func testKeepOtherOnOriginalTrashesOriginal() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.original.id, .keepOther)

        try assertTrashed(pair.original.id)
        try assertOpenAndUnmarked(pair.duplicate.id)
        XCTAssertTrue(try listConflictsSync().isEmpty)
    }

    func testKeepBothClearsMarkerAndLeavesBothOpen() throws {
        let pair = try makeConflictPair()
        let originalBefore = try store.recordByID(pair.original.id)
        try resolveSync(id: pair.original.id, .keepBoth)

        try assertOpenAndUnmarked(pair.original.id)
        try assertOpenAndUnmarked(pair.duplicate.id)
        XCTAssertEqual(try store.recordByID(pair.original.id)?.content, "server edit")
        XCTAssertEqual(try store.recordByID(pair.duplicate.id)?.content, "local edit")
        XCTAssertTrue(try listConflictsSync().isEmpty)
        XCTAssertTrue(try searchSync(onlyConflicts: true).isEmpty)

        // Only the duplicate changed; the original is not re-uploaded.
        XCTAssertEqual(try store.recordByID(pair.original.id), originalBefore)
        XCTAssertEqual(try store.pendingChanges().map(\.id), [pair.duplicate.id])
    }

    func testRestoreAfterResolutionDoesNotResurrectConflict() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.duplicate.id, .keepThis)

        let restored = try restoreFromTrashSync(id: pair.original.id)
        XCTAssertEqual(restored.status, RecordStatus.open.rawValue)
        XCTAssertTrue(try listConflictsSync().isEmpty)
        XCTAssertEqual(Set(try searchSync().map(\.id)), [pair.original.id, pair.duplicate.id])
    }

    func testResolutionWithoutCounterpartOnlyClearsMarker() throws {
        // Original already trashed elsewhere: Keep This has nothing to trash.
        let first = try makeConflictPair(local: "a local", server: "a server")
        try moveToTrashSync(id: first.original.id)
        let trashedAt = try store.recordByID(first.original.id)?.deletedAt
        try resolveSync(id: first.duplicate.id, .keepThis)
        try assertOpenAndUnmarked(first.duplicate.id)
        XCTAssertEqual(try store.recordByID(first.original.id)?.deletedAt, trashedAt)

        // Keep Other likewise must not trash the only remaining side.
        let second = try makeConflictPair(local: "b local", server: "b server")
        try moveToTrashSync(id: second.original.id)
        try resolveSync(id: second.duplicate.id, .keepOther)
        try assertOpenAndUnmarked(second.duplicate.id)

        XCTAssertTrue(try listConflictsSync().isEmpty)
    }

    func testResolveOnPlainRecordIsNoOp() throws {
        let record = try createSync("no conflict")
        try resolveSync(id: record.id, .keepThis)
        XCTAssertEqual(try store.recordByID(record.id), record)
    }

    func testResolveUnknownIdFails() throws {
        XCTAssertThrowsError(try resolveSync(id: "missing", .keepBoth)) { error in
            XCTAssertEqual(error as? RecordStoreError, .notFound)
        }
    }

    func testResolutionLeavesFTSMirrorUntouched() throws {
        let pair = try makeConflictPair()
        try resolveSync(id: pair.duplicate.id, .keepThis)

        XCTAssertEqual(try store.ftsContent(forRecordID: pair.original.id), "server edit")
        XCTAssertEqual(try store.ftsContent(forRecordID: pair.duplicate.id), "local edit")
        XCTAssertEqual(try searchSync("local").map(\.id), [pair.duplicate.id])
    }

    func testResolutionFiresOnDidCommitChangeForTouchedRows() throws {
        let pair = try makeConflictPair()
        let expectation = expectation(description: "callback")
        var received: [PendingChange] = []
        store.onDidCommitChange = { changes in
            received = changes
            DispatchQueue.main.async { expectation.fulfill() }
        }
        try resolveSync(id: pair.duplicate.id, .keepThis)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(Set(received.map(\.id)), [pair.original.id, pair.duplicate.id])
        XCTAssertTrue(received.allSatisfy { $0.entity == .record && $0.changeType == .upsert })
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
}
