import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class ProjectStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-project-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func listProjectsSync() throws -> [Project] {
        let expectation = expectation(description: "listProjects")
        var result: Result<[Project], Error>!
        store.projects.listProjects { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
    }

    // MARK: - Manual order append (PRD §7.4)

    func testCreateProjectAppendsToEndOfManualOrder() throws {
        let first = try createProjectSync("Alpha")
        let second = try createProjectSync("Beta")
        let third = try createProjectSync("Gamma")

        XCTAssertEqual(first.manualOrder, 0)
        XCTAssertEqual(second.manualOrder, 1)
        XCTAssertEqual(third.manualOrder, 2)
    }

    func testListProjectsOrderedByManualOrderAscending() throws {
        try createProjectSync("Alpha")
        try createProjectSync("Beta")
        try createProjectSync("Gamma")

        let list = try listProjectsSync()
        XCTAssertEqual(list.map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(list.map(\.manualOrder), [0, 1, 2])
    }

    func testListProjectsEmptyWhenNoneCreated() throws {
        XCTAssertEqual(try listProjectsSync(), [])
    }

    // MARK: - Name handling

    func testCreateProjectTrimsWhitespaceFromName() throws {
        let project = try createProjectSync("  Spacey Name  ")
        XCTAssertEqual(project.name, "Spacey Name")
    }

    func testCreateProjectRejectsEmptyOrWhitespaceOnlyName() throws {
        XCTAssertThrowsError(try createProjectSync(""))
        XCTAssertThrowsError(try createProjectSync("   "))

        // A rejected create must not have consumed a manual_order slot.
        let next = try createProjectSync("Real Project")
        XCTAssertEqual(next.manualOrder, 0)
    }

    private func renameProjectSync(id: String, name: String) throws {
        let expectation = expectation(description: "renameProject")
        var result: Result<Void, Error>!
        store.projects.renameProject(id: id, name: name) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func deleteProjectSync(id: String) throws {
        let expectation = expectation(description: "deleteProject")
        var result: Result<Void, Error>!
        store.projects.deleteProject(id: id) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    private func reorderProjectsSync(_ orderedIDs: [String]) throws {
        let expectation = expectation(description: "reorderProjects")
        var result: Result<Void, Error>!
        store.projects.reorderProjects(orderedIDs: orderedIDs) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        try result.get()
    }

    @discardableResult
    private func createRecordSync(_ content: String, projectID: String? = nil) throws -> Record {
        let expectation = expectation(description: "createRecord")
        var result: Result<Record, Error>!
        store.createRecord(content: content, projectID: projectID) { r in
            result = r
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return try result.get()
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

    // MARK: - Stable identity

    func testCreateProjectAssignsUniqueIDsAndTimestamps() throws {
        let first = try createProjectSync("One")
        let second = try createProjectSync("Two")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertEqual(first.createdAt, first.updatedAt)
    }

    // MARK: - Rename (PRD §7.5)

    func testRenameProjectUpdatesNameAndTimestamp() throws {
        let project = try createProjectSync("Old Name")
        try renameProjectSync(id: project.id, name: "New Name")

        let list = try listProjectsSync()
        XCTAssertEqual(list.map(\.name), ["New Name"])
        XCTAssertEqual(list.first?.id, project.id)
        XCTAssertGreaterThanOrEqual(list.first?.updatedAt ?? -1, project.updatedAt)
    }

    func testRenameProjectTrimsWhitespace() throws {
        let project = try createProjectSync("Alpha")
        try renameProjectSync(id: project.id, name: "  Beta  ")
        XCTAssertEqual(try listProjectsSync().first?.name, "Beta")
    }

    func testRenameProjectRejectsEmptyName() throws {
        let project = try createProjectSync("Alpha")
        XCTAssertThrowsError(try renameProjectSync(id: project.id, name: "   "))
        XCTAssertEqual(try listProjectsSync().first?.name, "Alpha")
    }

    // MARK: - Delete (PRD §7.5)

    func testDeleteProjectRemovesProjectAndClearsOpenRecordProjectID() throws {
        let project = try createProjectSync("Work")
        let record = try createRecordSync("belongs to work", projectID: project.id)

        try deleteProjectSync(id: project.id)

        XCTAssertEqual(try listProjectsSync(), [])
        let stored = try store.recordByID(record.id)
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.projectID)
        XCTAssertEqual(stored?.content, "belongs to work")
        XCTAssertGreaterThanOrEqual(stored?.updatedAt ?? -1, record.updatedAt)
    }

    func testDeleteProjectClearsTrashedAndResolvedRecordProjectIDs() throws {
        let project = try createProjectSync("Work")
        let open = try createRecordSync("open", projectID: project.id)
        let resolved = try createRecordSync("resolved", projectID: project.id)
        let trashed = try createRecordSync("trashed", projectID: project.id)
        try setStatusSync(id: resolved.id, status: .resolved)
        try setStatusSync(id: trashed.id, status: .trashed)

        try deleteProjectSync(id: project.id)

        XCTAssertNil(try store.recordByID(open.id)?.projectID)
        XCTAssertNil(try store.recordByID(resolved.id)?.projectID)
        XCTAssertNil(try store.recordByID(trashed.id)?.projectID)
        XCTAssertEqual(try store.recordByID(resolved.id)?.status, RecordStatus.resolved.rawValue)
        XCTAssertEqual(try store.recordByID(trashed.id)?.status, RecordStatus.trashed.rawValue)
    }

    func testDeleteProjectLeavesOtherProjectsAndTheirRecordsUntouched() throws {
        let keep = try createProjectSync("Keep")
        let drop = try createProjectSync("Drop")
        let keptRecord = try createRecordSync("stay", projectID: keep.id)
        try createRecordSync("go", projectID: drop.id)

        try deleteProjectSync(id: drop.id)

        let list = try listProjectsSync()
        XCTAssertEqual(list.map(\.id), [keep.id])
        XCTAssertEqual(try store.recordByID(keptRecord.id)?.projectID, keep.id)
    }

    // MARK: - Reorder (PRD §7.4)

    func testReorderProjectsRewritesManualOrderAsZeroBasedSequence() throws {
        let alpha = try createProjectSync("Alpha")
        let beta = try createProjectSync("Beta")
        let gamma = try createProjectSync("Gamma")

        try reorderProjectsSync([gamma.id, alpha.id, beta.id])

        let list = try listProjectsSync()
        XCTAssertEqual(list.map(\.name), ["Gamma", "Alpha", "Beta"])
        XCTAssertEqual(list.map(\.manualOrder), [0, 1, 2])
        XCTAssertEqual(list.map(\.id), [gamma.id, alpha.id, beta.id])
    }

    func testReorderProjectsRejectsIncompleteOrUnknownIDList() throws {
        let alpha = try createProjectSync("Alpha")
        let beta = try createProjectSync("Beta")

        XCTAssertThrowsError(try reorderProjectsSync([alpha.id])) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidReorder)
        }
        XCTAssertThrowsError(try reorderProjectsSync([alpha.id, beta.id, "missing"])) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidReorder)
        }
        XCTAssertEqual(try listProjectsSync().map(\.name), ["Alpha", "Beta"])
    }

    func testReorderProjectsEmptyListSucceedsWhenNoProjectsExist() throws {
        XCTAssertNoThrow(try reorderProjectsSync([]))
        XCTAssertEqual(try listProjectsSync(), [])
    }
}
