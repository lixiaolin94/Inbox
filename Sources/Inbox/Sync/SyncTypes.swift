import Foundation

/// Local change-tracking entity names. Kept as raw strings so the SQLite
/// `pending_change` / `tombstone` tables stay readable without CloudKit types.
enum SyncEntity: String, Equatable {
    case record
    case project
}

enum SyncChangeType: String, Equatable {
    case upsert
    case delete
}

struct PendingChange: Equatable {
    var entity: SyncEntity
    var id: String
    var changeType: SyncChangeType
}

struct Tombstone: Equatable {
    var entity: SyncEntity
    var id: String
    var deletedAt: Int64
}

extension Notification.Name {
    /// Posted on the main queue after a remote CloudKit batch has been
    /// applied to the local store. MainViewController re-runs search.
    static let inboxDidApplyRemoteChanges = Notification.Name("com.xiaolin.Inbox.didApplyRemoteChanges")
}

/// Result of applying a fetched Record/Project payload onto the local row.
enum FetchedApplyResult: Equatable {
    case applied
    /// Local unsent edits mixed with the remote version; caller should
    /// re-queue an upsert for `id`.
    case appliedNeedsUpload(id: String)
    /// Content Keep Both: original id now holds the server content; a new
    /// local row was inserted at `duplicateID`.
    case keepBothNeedsUpload(originalID: String, duplicateID: String)
    /// Local permanent-delete is newer than the fetched payload; caller
    /// should re-queue a delete so the tombstone wins on the server.
    case retainedTombstone(id: String)
}

enum RemoteDeletionResult: Equatable {
    case deleted
    /// Local unsent edits beat the remote tombstone (PRD §15.3). Caller
    /// should re-queue an upsert so the edit is resurrected on the server.
    case retainedNeedsUpload
    case alreadyGone
}

/// SQLite helpers for `pending_change` and `tombstone`. Called only from
/// the RecordStore serial queue, inside an open transaction for writes.
enum SyncTracking {
    static func registerPending(
        db: SQLiteDatabase,
        entity: SyncEntity,
        id: String,
        changeType: SyncChangeType
    ) throws {
        try db.run(
            """
            INSERT INTO pending_change (entity, id, change_type)
            VALUES (?, ?, ?)
            ON CONFLICT(entity, id) DO UPDATE SET change_type = excluded.change_type
            """,
            bindings: [.text(entity.rawValue), .text(id), .text(changeType.rawValue)]
        )
    }

    static func clearPending(db: SQLiteDatabase, entity: SyncEntity, id: String) throws {
        try db.run(
            "DELETE FROM pending_change WHERE entity = ? AND id = ?",
            bindings: [.text(entity.rawValue), .text(id)]
        )
    }

    static func pending(db: SQLiteDatabase, entity: SyncEntity, id: String) throws -> PendingChange? {
        var found: PendingChange?
        try db.query(
            "SELECT change_type FROM pending_change WHERE entity = ? AND id = ?",
            bindings: [.text(entity.rawValue), .text(id)]
        ) { stmt in
            let raw = columnText(stmt, 0) ?? ""
            found = SyncChangeType(rawValue: raw).map {
                PendingChange(entity: entity, id: id, changeType: $0)
            }
        }
        return found
    }

    static func loadPending(db: SQLiteDatabase) throws -> [PendingChange] {
        var changes: [PendingChange] = []
        try db.query("SELECT entity, id, change_type FROM pending_change") { stmt in
            guard let entity = SyncEntity(rawValue: columnText(stmt, 0) ?? ""),
                  let id = columnText(stmt, 1),
                  let changeType = SyncChangeType(rawValue: columnText(stmt, 2) ?? "") else {
                return
            }
            changes.append(PendingChange(entity: entity, id: id, changeType: changeType))
        }
        return changes
    }

    static func insertTombstone(
        db: SQLiteDatabase,
        entity: SyncEntity,
        id: String,
        deletedAt: Int64
    ) throws {
        try db.run(
            """
            INSERT INTO tombstone (entity, id, deleted_at)
            VALUES (?, ?, ?)
            ON CONFLICT(entity, id) DO UPDATE SET deleted_at = excluded.deleted_at
            """,
            bindings: [.text(entity.rawValue), .text(id), .int64(deletedAt)]
        )
    }

    static func removeTombstone(db: SQLiteDatabase, entity: SyncEntity, id: String) throws {
        try db.run(
            "DELETE FROM tombstone WHERE entity = ? AND id = ?",
            bindings: [.text(entity.rawValue), .text(id)]
        )
    }

    static func tombstone(db: SQLiteDatabase, entity: SyncEntity, id: String) throws -> Tombstone? {
        var found: Tombstone?
        try db.query(
            "SELECT deleted_at FROM tombstone WHERE entity = ? AND id = ?",
            bindings: [.text(entity.rawValue), .text(id)]
        ) { stmt in
            found = Tombstone(entity: entity, id: id, deletedAt: columnInt64(stmt, 0))
        }
        return found
    }

    static func loadTombstones(db: SQLiteDatabase) throws -> [Tombstone] {
        var rows: [Tombstone] = []
        try db.query("SELECT entity, id, deleted_at FROM tombstone") { stmt in
            guard let entity = SyncEntity(rawValue: columnText(stmt, 0) ?? ""),
                  let id = columnText(stmt, 1) else {
                return
            }
            rows.append(Tombstone(entity: entity, id: id, deletedAt: columnInt64(stmt, 2)))
        }
        return rows
    }

    static func systemFields(db: SQLiteDatabase, entity: SyncEntity, id: String) throws -> Data? {
        let table = entity == .record ? "record" : "project"
        var data: Data?
        try db.query(
            "SELECT ck_system_fields FROM \(table) WHERE id = ?",
            bindings: [.text(id)]
        ) { stmt in
            data = columnBlob(stmt, 0)
        }
        return data
    }

    static func saveSystemFields(
        db: SQLiteDatabase,
        entity: SyncEntity,
        id: String,
        data: Data?
    ) throws {
        let table = entity == .record ? "record" : "project"
        try db.run(
            "UPDATE \(table) SET ck_system_fields = ? WHERE id = ?",
            bindings: [data.map(SQLiteValue.blob) ?? .null, .text(id)]
        )
    }
}

/// Envelope stored in `ck_system_fields`: Apple's encodeSystemFields blob
/// plus a JSON snapshot of the last-acked payload (the three-way ancestor).
/// System fields alone have the change tag but not field values, so the
/// ancestor snapshot is required for PRD §15.3 field-level merge.
enum CKLocalMetadata {
    private static let version: Int64 = 1

    static func pack(systemFields: Data, ancestorJSON: String) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(version, forKey: "v")
        archiver.encode(systemFields, forKey: "sys")
        archiver.encode(ancestorJSON, forKey: "anc")
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func unpack(_ data: Data) -> (systemFields: Data, ancestorJSON: String)? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        guard let sys = unarchiver.decodeObject(of: NSData.self, forKey: "sys") as Data? else {
            return nil
        }
        let ancestor = unarchiver.decodeObject(of: NSString.self, forKey: "anc") as String? ?? ""
        return (sys, ancestor)
    }
}
