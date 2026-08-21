import Foundation

enum ProjectStoreError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case invalidReorder

    var description: String {
        switch self {
        case .emptyName: return "project name must not be empty"
        case .invalidReorder: return "reorder list must be a permutation of existing project ids"
        }
    }
}

/// Project CRUD. Deliberately shares RecordStore's single serial queue and
/// single SQLiteDatabase connection rather than opening a second one —
/// RecordStore constructs this and owns both, per SPEC's one-connection rule.
final class ProjectStore {
    private let queue: DispatchQueue
    private let db: SQLiteDatabase

    /// Same callback RecordStore exposes; set via RecordStore.onDidCommitChange.
    var onDidCommitChange: (([PendingChange]) -> Void)?

    init(db: SQLiteDatabase, queue: DispatchQueue) {
        self.db = db
        self.queue = queue
    }

    /// Appends to the end of the manual order (PRD §7.4): `manual_order` is
    /// current max + 1, computed and inserted inside one transaction so two
    /// concurrent creates can't race to the same order value.
    func createProject(name: String, completion: @escaping (Result<Project, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.insert(db: self.db, name: name) }
            if case .success(let project) = result {
                self.onDidCommitChange?([PendingChange(entity: .project, id: project.id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Ordered by `manual_order` ascending — the single order source shared
    /// by the Scope Bar, All View grouping, and `⌘Number` mapping.
    func listProjects(completion: @escaping (Result<[Project], Error>) -> Void) {
        queue.async { [db] in
            let result = Result { try Self.fetchAll(db: db) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func renameProject(id: String, name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.rename(db: self.db, id: id, name: name) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .project, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Deletes the Project row and clears `project_id` on every Record that
    /// pointed at it, including `status = trashed` rows, in one transaction
    /// (PRD §7.5). Records themselves are not deleted.
    func deleteProject(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.delete(db: self.db, id: id) }
            if case .success(let changes) = result {
                self.onDidCommitChange?(changes)
            }
            DispatchQueue.main.async { completion(result.map { _ in () }) }
        }
    }

    /// Rewrites `manual_order` to `0..<n` for the given permutation of every
    /// existing Project id, in one transaction (PRD §7.4).
    func reorderProjects(orderedIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.reorder(db: self.db, orderedIDs: orderedIDs) }
            if case .success(let changes) = result {
                self.onDidCommitChange?(changes)
            }
            DispatchQueue.main.async { completion(result.map { _ in () }) }
        }
    }

    // MARK: - Queries (run on `queue`)

    private static func insert(db: SQLiteDatabase, name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectStoreError.emptyName }

        let id = UUID().uuidString
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            var maxOrder: Int64 = -1
            try db.query("SELECT COALESCE(MAX(manual_order), -1) FROM project") { stmt in
                maxOrder = columnInt64(stmt, 0)
            }
            let order = maxOrder + 1
            try db.run(
                "INSERT INTO project (id, name, manual_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                bindings: [.text(id), .text(trimmed), .int64(order), .int64(now), .int64(now)]
            )
            try SyncTracking.registerPending(db: db, entity: .project, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
            return Project(id: id, name: trimmed, manualOrder: order, createdAt: now, updatedAt: now)
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func rename(db: SQLiteDatabase, id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectStoreError.emptyName }

        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                "UPDATE project SET name = ?, updated_at = ? WHERE id = ?",
                bindings: [.text(trimmed), .int64(now), .text(id)]
            )
            try SyncTracking.registerPending(db: db, entity: .project, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func delete(db: SQLiteDatabase, id: String) throws -> [PendingChange] {
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            var affectedRecordIDs: [String] = []
            try db.query(
                "SELECT id FROM record WHERE project_id = ?",
                bindings: [.text(id)]
            ) { stmt in
                if let recordID = columnText(stmt, 0) {
                    affectedRecordIDs.append(recordID)
                }
            }
            try db.run(
                "UPDATE record SET project_id = NULL, updated_at = ? WHERE project_id = ?",
                bindings: [.int64(now), .text(id)]
            )
            try db.run(
                "DELETE FROM project WHERE id = ?",
                bindings: [.text(id)]
            )
            try SyncTracking.insertTombstone(db: db, entity: .project, id: id, deletedAt: now)
            try SyncTracking.registerPending(db: db, entity: .project, id: id, changeType: .delete)
            var changes = [PendingChange(entity: .project, id: id, changeType: .delete)]
            for recordID in affectedRecordIDs {
                try SyncTracking.registerPending(db: db, entity: .record, id: recordID, changeType: .upsert)
                changes.append(PendingChange(entity: .record, id: recordID, changeType: .upsert))
            }
            try db.exec("COMMIT;")
            return changes
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func reorder(db: SQLiteDatabase, orderedIDs: [String]) throws -> [PendingChange] {
        let existing = try fetchAll(db: db)
        guard existing.count == orderedIDs.count,
              Set(existing.map(\.id)) == Set(orderedIDs) else {
            throw ProjectStoreError.invalidReorder
        }

        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            var changes: [PendingChange] = []
            for (index, id) in orderedIDs.enumerated() {
                try db.run(
                    "UPDATE project SET manual_order = ?, updated_at = ? WHERE id = ?",
                    bindings: [.int64(Int64(index)), .int64(now), .text(id)]
                )
                try SyncTracking.registerPending(db: db, entity: .project, id: id, changeType: .upsert)
                changes.append(PendingChange(entity: .project, id: id, changeType: .upsert))
            }
            try db.exec("COMMIT;")
            return changes
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func fetchAll(db: SQLiteDatabase) throws -> [Project] {
        var projects: [Project] = []
        try db.query(
            "SELECT id, name, manual_order, created_at, updated_at FROM project ORDER BY manual_order ASC"
        ) { stmt in
            projects.append(
                Project(
                    id: columnText(stmt, 0) ?? "",
                    name: columnText(stmt, 1) ?? "",
                    manualOrder: columnInt64(stmt, 2),
                    createdAt: columnInt64(stmt, 3),
                    updatedAt: columnInt64(stmt, 4)
                )
            )
        }
        return projects
    }

    static func fetchByID(db: SQLiteDatabase, id: String) throws -> Project? {
        var found: Project?
        try db.query(
            "SELECT id, name, manual_order, created_at, updated_at FROM project WHERE id = ?",
            bindings: [.text(id)]
        ) { stmt in
            found = Project(
                id: columnText(stmt, 0) ?? "",
                name: columnText(stmt, 1) ?? "",
                manualOrder: columnInt64(stmt, 2),
                createdAt: columnInt64(stmt, 3),
                updatedAt: columnInt64(stmt, 4)
            )
        }
        return found
    }

    static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
