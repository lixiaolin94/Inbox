import Foundation

enum RecordStoreError: Error, Equatable, CustomStringConvertible {
    case notFound

    var description: String {
        switch self {
        case .notFound: return "record not found"
        }
    }
}

/// Local SQLite-backed storage for Records.
///
/// All DB access runs on a single serial queue; every public method dispatches
/// there and calls its completion back on the main queue, per SPEC's
/// concurrency rule (UI on main thread, DB on one serial queue).
///
/// Search strategy (see delivery notes): a `record_fts` FTS5 mirror (trigram
/// tokenizer) is created and kept in sync on every write, satisfying the
/// "must maintain an FTS5 index" requirement. The actual query path used by
/// `search(term:)` does NOT use FTS5 MATCH — it runs `content LIKE '%term%'`
/// against the source-of-truth `record` table instead. Reason: FTS5's
/// unicode61 tokenizer does not segment CJK text at all (whole runs become a
/// single token, so substring MATCH never fires), and the trigram tokenizer
/// requires the query to be >= 3 codepoints, which rules out the very common
/// case of a 1–2 character Chinese search term. A bound-parameter LIKE scan
/// is correct for any language and length at the current data scale
/// (measured: 10k-row LIKE scan completes in ~1-2ms, well inside the 50ms/10k
/// budget in PRD §17.3), so correctness wins over MATCH-based ranking for
/// this Slice.
final class RecordStore {
    let queue = DispatchQueue(label: "com.inbox.recordstore")
    let db: SQLiteDatabase

    /// Project CRUD, sharing this store's queue and connection (PRD §3.3).
    let projects: ProjectStore

    /// Fired on the DB serial queue after a local write commits. The sync
    /// layer subscribes; CloudKit types must not appear here.
    var onDidCommitChange: (([PendingChange]) -> Void)? {
        didSet { projects.onDidCommitChange = onDidCommitChange }
    }

    init(databasePath: String) throws {
        let directory = (databasePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: databasePath)
        try Self.migrate(db)
        projects = ProjectStore(db: db, queue: queue)
    }

    convenience init() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Inbox", isDirectory: true)
        let databasePath = supportDirectory.appendingPathComponent("inbox.sqlite").path
        try self.init(databasePath: databasePath)
    }

    // MARK: - Writes

    func createRecord(
        content: String,
        projectID: String? = nil,
        completion: @escaping (Result<Record, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.insert(db: self.db, content: content, projectID: projectID) }
            if case .success(let record) = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: record.id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func updateContent(
        id: String,
        content: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.update(db: self.db, id: id, content: content) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Persists a Row Focus `←/→` Priority change (PRD §8.4). `priority` must
    /// already be a valid Priority.rawValue — boundary clamping happens in
    /// `Priority.raised`/`.lowered` before this is called.
    func updatePriority(
        id: String,
        priority: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        precondition(Priority(rawValue: priority) != nil, "priority out of range: \(priority)")
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.applyPriorityUpdate(db: self.db, id: id, priority: priority) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Persists Resolve/Reopen (PRD §8.6). Bidirectional: Resolve sets
    /// `resolvedAt`; Reopen (Space on a Resolved row) clears it back to nil.
    func setStatus(
        id: String,
        status: RecordStatus,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.updateStatus(db: self.db, id: id, status: status) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Moves a Record to a Project, or to Inbox when `projectID` is nil
    /// (PRD §8.7). Does not validate that `projectID` exists — the UI only
    /// offers current Projects.
    func updateProject(
        id: String,
        projectID: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.applyProjectUpdate(db: self.db, id: id, projectID: projectID) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Soft-delete (PRD §8.8): `status = trashed`, `deleted_at = now`,
    /// `updated_at = now`. Leaves every other column — including
    /// `resolved_at` and `project_id` — untouched so Restore is lossless.
    func moveToTrash(
        id: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.applyMoveToTrash(db: self.db, id: id) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Inverse of `moveToTrash` (PRD §8.8 / §19.6). Restores `status` from
    /// `resolved_at` (non-nil → resolved, else open) and clears `deleted_at`.
    /// Missing id is `RecordStoreError.notFound`; a non-trashed row is
    /// returned unchanged.
    func restoreFromTrash(
        id: String,
        completion: @escaping (Result<Record, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.applyRestoreFromTrash(db: self.db, id: id) }
            if case .success = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .upsert)])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Physical delete of a trashed row plus its `record_fts` mirror
    /// (PRD §12.3). No-ops if the row is missing or not trashed — open /
    /// resolved Records cannot be destroyed through this path.
    func permanentlyDelete(
        id: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.applyPermanentDelete(db: self.db, id: id) }
            if case .success(true) = result {
                self.onDidCommitChange?([PendingChange(entity: .record, id: id, changeType: .delete)])
            }
            DispatchQueue.main.async { completion(result.map { _ in () }) }
        }
    }

    // MARK: - Batch plumbing (multi-select)

    /// Fires `operation` once per id and reports once after the last
    /// completion. All store completions land on the main queue, in order,
    /// so the shared counters need no locking. On any failure the caller
    /// gets the first error; the serial queue has still applied the other
    /// writes, so callers must re-sync from the DB rather than patch local
    /// state.
    static func batch(
        ids: [String],
        operation: (String, @escaping (Result<Void, Error>) -> Void) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard !ids.isEmpty else {
            completion(nil)
            return
        }
        var remaining = ids.count
        var firstError: Error?
        for id in ids {
            operation(id) { result in
                if case .failure(let error) = result, firstError == nil {
                    firstError = error
                }
                remaining -= 1
                if remaining == 0 {
                    completion(firstError)
                }
            }
        }
    }

    // MARK: - Reads

    /// `token` is echoed back unchanged so the caller can discard results
    /// from a stale (superseded) search that resolves after a newer one.
    /// `scope` is the only source of search range (PRD §6.6): `.all` matches
    /// every Record regardless of Project, `.project` matches only that one.
    /// `includeResolved` is the Show Resolved visibility flag (PRD §6.6, §11):
    /// Off (default) searches Open only; On searches Open and Resolved in
    /// the current Scope. Trashed rows are never returned here.
    func search(
        term: String,
        scope: Scope,
        token: Int,
        sortOrder: RecordSort = .newestFirst,
        includeResolved: Bool = false,
        completion: @escaping (Result<[Record], Error>, Int) -> Void
    ) {
        queue.async { [db] in
            let result = Result {
                try Self.fetch(
                    db: db,
                    searchTerm: term,
                    scope: scope,
                    sortOrder: sortOrder,
                    includeResolved: includeResolved
                )
            }
            DispatchQueue.main.async { completion(result, token) }
        }
    }

    /// Trashed Records newest-deleted first (PRD §12). Includes `project_id`
    /// so the Trash surface can group by Inbox / Project.
    func listTrashed(completion: @escaping (Result<[Record], Error>) -> Void) {
        queue.async { [db] in
            let result = Result { try Self.fetchTrashed(db: db) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Test-only accessor that bypasses the `status = 0` filter `search`
    /// applies, so tests can observe a Record right after it's Resolved.
    /// Not used by production/UI code.
    func recordByID(_ id: String) throws -> Record? {
        try queue.sync {
            try Self.fetchByID(db: db, id: id)
        }
    }

    /// Test-only accessor confirming the FTS5 mirror stays in sync with
    /// `record.content`. Not used by production/UI code.
    func ftsContent(forRecordID id: String) throws -> String? {
        try queue.sync {
            var result: String?
            try db.query(
                "SELECT content FROM record_fts WHERE record_id = ?",
                bindings: [.text(id)]
            ) { stmt in
                result = columnText(stmt, 0)
            }
            return result
        }
    }

    // MARK: - Schema

    private static let schemaV1SQL = """
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
    """

    /// Adds Project (PRD §3.3). `record.project_id` already existed in v1 as
    /// a loose TEXT column, so no migration is needed on the `record` side —
    /// only the new `project` table itself.
    private static let schemaV2SQL = """
    CREATE TABLE project (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        manual_order INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    """

    /// CloudKit sync metadata (S6). `ck_system_fields` is an envelope of
    /// encodeSystemFields + last-acked payload JSON (see CKLocalMetadata).
    /// Existing rows get NULL (never uploaded) and a pending upsert so the
    /// first sync uploads the local library.
    private static let schemaV3SQL = """
    ALTER TABLE record ADD COLUMN ck_system_fields BLOB;
    ALTER TABLE project ADD COLUMN ck_system_fields BLOB;
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
    INSERT INTO pending_change (entity, id, change_type)
        SELECT 'record', id, 'upsert' FROM record;
    INSERT INTO pending_change (entity, id, change_type)
        SELECT 'project', id, 'upsert' FROM project;
    """

    /// Runs each pending version step in order inside its own transaction, so
    /// a v1 database upgrades in place and a brand-new database walks the
    /// same path from 0. Each step is independently rollback-safe.
    private static func migrate(_ db: SQLiteDatabase) throws {
        if try db.userVersion() < 1 {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                try db.exec(schemaV1SQL)
                try db.setUserVersion(1)
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
        if try db.userVersion() < 2 {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                try db.exec(schemaV2SQL)
                try db.setUserVersion(2)
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
        if try db.userVersion() < 3 {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                try db.exec(schemaV3SQL)
                try db.setUserVersion(3)
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Queries (run on `queue`)

    private static func insert(db: SQLiteDatabase, content: String, projectID: String?) throws -> Record {
        let id = UUID().uuidString
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                """
                INSERT INTO record
                    (id, content, priority, status, project_id, created_at, updated_at, resolved_at, deleted_at)
                VALUES (?, ?, 2, 0, ?, ?, ?, NULL, NULL)
                """,
                bindings: [
                    .text(id), .text(content), projectID.map(SQLiteValue.text) ?? .null, .int64(now), .int64(now)
                ]
            )
            try db.run(
                "INSERT INTO record_fts (record_id, content) VALUES (?, ?)",
                bindings: [.text(id), .text(content)]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return Record(
            id: id, content: content, priority: 2, status: 0, projectID: projectID,
            createdAt: now, updatedAt: now, resolvedAt: nil, deletedAt: nil
        )
    }

    private static func update(db: SQLiteDatabase, id: String, content: String) throws {
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                "UPDATE record SET content = ?, updated_at = ? WHERE id = ?",
                bindings: [.text(content), .int64(now), .text(id)]
            )
            try db.run(
                "UPDATE record_fts SET content = ? WHERE record_id = ?",
                bindings: [.text(content), .text(id)]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func applyPriorityUpdate(db: SQLiteDatabase, id: String, priority: Int) throws {
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                "UPDATE record SET priority = ?, updated_at = ? WHERE id = ?",
                bindings: [.int64(Int64(priority)), .int64(now), .text(id)]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func updateStatus(db: SQLiteDatabase, id: String, status: RecordStatus) throws {
        let now = currentTimeMillis()
        let resolvedAt: SQLiteValue = status == .resolved ? .int64(now) : .null
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                "UPDATE record SET status = ?, resolved_at = ?, updated_at = ? WHERE id = ?",
                bindings: [.int64(Int64(status.rawValue)), resolvedAt, .int64(now), .text(id)]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func applyProjectUpdate(db: SQLiteDatabase, id: String, projectID: String?) throws {
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.run(
                "UPDATE record SET project_id = ?, updated_at = ? WHERE id = ?",
                bindings: [projectID.map(SQLiteValue.text) ?? .null, .int64(now), .text(id)]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func applyMoveToTrash(db: SQLiteDatabase, id: String) throws {
        let now = currentTimeMillis()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            guard try fetchByID(db: db, id: id) != nil else {
                throw RecordStoreError.notFound
            }
            try db.run(
                "UPDATE record SET status = ?, deleted_at = ?, updated_at = ? WHERE id = ?",
                bindings: [
                    .int64(Int64(RecordStatus.trashed.rawValue)),
                    .int64(now),
                    .int64(now),
                    .text(id)
                ]
            )
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func applyRestoreFromTrash(db: SQLiteDatabase, id: String) throws -> Record {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            guard var record = try fetchByID(db: db, id: id) else {
                throw RecordStoreError.notFound
            }
            if record.status == RecordStatus.trashed.rawValue {
                let now = currentTimeMillis()
                let restoredStatus = record.resolvedAt == nil
                    ? RecordStatus.open.rawValue
                    : RecordStatus.resolved.rawValue
                try db.run(
                    "UPDATE record SET status = ?, deleted_at = NULL, updated_at = ? WHERE id = ?",
                    bindings: [.int64(Int64(restoredStatus)), .int64(now), .text(id)]
                )
                record.status = restoredStatus
                record.deletedAt = nil
                record.updatedAt = now
                try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
            }
            try db.exec("COMMIT;")
            return record
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// Returns true when a trashed row was physically removed (and a
    /// tombstone + pending delete recorded). False is a no-op.
    private static func applyPermanentDelete(db: SQLiteDatabase, id: String) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let record = try fetchByID(db: db, id: id)
            var didDelete = false
            if record?.status == RecordStatus.trashed.rawValue {
                try db.run("DELETE FROM record WHERE id = ?", bindings: [.text(id)])
                try db.run("DELETE FROM record_fts WHERE record_id = ?", bindings: [.text(id)])
                try SyncTracking.insertTombstone(
                    db: db,
                    entity: .record,
                    id: id,
                    deletedAt: currentTimeMillis()
                )
                try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .delete)
                didDelete = true
            }
            try db.exec("COMMIT;")
            return didDelete
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func fetchTrashed(db: SQLiteDatabase) throws -> [Record] {
        var records: [Record] = []
        try db.query(
            """
            SELECT \(recordColumns) FROM record
            WHERE status = ?
            ORDER BY deleted_at DESC
            """,
            bindings: [.int64(Int64(RecordStatus.trashed.rawValue))]
        ) { stmt in
            records.append(recordFromRow(stmt))
        }
        return records
    }

    static let recordColumns =
        "id, content, priority, status, project_id, created_at, updated_at, resolved_at, deleted_at"

    static func fetchByID(db: SQLiteDatabase, id: String) throws -> Record? {
        var result: Record?
        try db.query(
            "SELECT \(recordColumns) FROM record WHERE id = ?",
            bindings: [.text(id)]
        ) { stmt in
            result = recordFromRow(stmt)
        }
        return result
    }

    private static func fetch(
        db: SQLiteDatabase,
        searchTerm: String,
        scope: Scope,
        sortOrder: RecordSort,
        includeResolved: Bool
    ) throws -> [Record] {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let columns = recordColumns
        let order = sortOrder.sqlOrderClause

        var conditions: [String]
        if includeResolved {
            conditions = ["status IN (0, 1)"]
        } else {
            conditions = ["status = 0"]
        }
        var bindings: [SQLiteValue] = []
        if case .project(let projectID) = scope {
            conditions.append("project_id = ?")
            bindings.append(.text(projectID))
        }
        if !trimmed.isEmpty {
            conditions.append("content LIKE ? ESCAPE '\\'")
            bindings.append(.text("%" + escapeLikePattern(trimmed) + "%"))
        }

        var records: [Record] = []
        try db.query(
            "SELECT \(columns) FROM record WHERE \(conditions.joined(separator: " AND ")) \(order)",
            bindings: bindings
        ) { stmt in
            records.append(recordFromRow(stmt))
        }
        return records
    }

    static func recordFromRow(_ stmt: OpaquePointer) -> Record {
        Record(
            id: columnText(stmt, 0) ?? "",
            content: columnText(stmt, 1) ?? "",
            priority: Int(columnInt64(stmt, 2)),
            status: Int(columnInt64(stmt, 3)),
            projectID: columnText(stmt, 4),
            createdAt: columnInt64(stmt, 5),
            updatedAt: columnInt64(stmt, 6),
            resolvedAt: columnInt64OrNil(stmt, 7),
            deletedAt: columnInt64OrNil(stmt, 8)
        )
    }

    private static func escapeLikePattern(_ term: String) -> String {
        var result = ""
        result.reserveCapacity(term.count)
        for character in term {
            switch character {
            case "\\": result += "\\\\"
            case "%": result += "\\%"
            case "_": result += "\\_"
            default: result.append(character)
            }
        }
        return result
    }

    static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
