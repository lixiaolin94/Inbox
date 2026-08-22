import Foundation

extension RecordStore {
    func syncPerform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pendingChanges() throws -> [PendingChange] {
        try queue.sync { try SyncTracking.loadPending(db: db) }
    }

    func tombstones() throws -> [Tombstone] {
        try queue.sync { try SyncTracking.loadTombstones(db: db) }
    }

    func ckSystemFields(entity: SyncEntity, id: String) throws -> Data? {
        try queue.sync { try SyncTracking.systemFields(db: db, entity: entity, id: id) }
    }

    func userVersion() throws -> Int {
        try queue.sync { try db.userVersion() }
    }

    /// Exact-content lookup used by `--sync-probe expect`. Includes Trash.
    func recordWithExactContent(_ content: String) throws -> Record? {
        try queue.sync {
            var found: Record?
            try db.query(
                "SELECT \(Self.recordColumns) FROM record WHERE content = ? LIMIT 1",
                bindings: [.text(content)]
            ) { stmt in
                found = Self.recordFromRow(stmt)
            }
            return found
        }
    }

    func applyFetchedRecord(
        id: String,
        payload: ConflictMerger.RecordFields,
        metadata: Data?
    ) throws -> FetchedApplyResult {
        try queue.sync {
            try Self.applyFetchedRecord(db: db, id: id, payload: payload, metadata: metadata)
        }
    }

    func applyFetchedProject(
        id: String,
        payload: ConflictMerger.ProjectFields,
        metadata: Data?
    ) throws -> FetchedApplyResult {
        try queue.sync {
            try Self.applyFetchedProject(db: db, id: id, payload: payload, metadata: metadata)
        }
    }

    func applyRemoteDeletion(entity: SyncEntity, id: String) throws -> RemoteDeletionResult {
        try queue.sync {
            try Self.applyRemoteDeletion(db: db, entity: entity, id: id)
        }
    }

    func loadRecordForUpload(id: String) throws -> (Record, Data?)? {
        try queue.sync {
            try Self.loadRecordForUpload(db: db, id: id)
        }
    }

    func loadProjectForUpload(id: String) throws -> (Project, Data?)? {
        try queue.sync {
            try Self.loadProjectForUpload(db: db, id: id)
        }
    }

    func acknowledgeUpload(entity: SyncEntity, id: String, metadata: Data) throws {
        try queue.sync {
            try Self.acknowledgeUpload(db: db, entity: entity, id: id, metadata: metadata)
        }
    }

    func acknowledgeDeletion(entity: SyncEntity, id: String) throws {
        try queue.sync {
            try Self.acknowledgeDeletion(db: db, entity: entity, id: id)
        }
    }

    // MARK: On-queue implementations (also used via syncPerform)

    static func applyFetchedRecord(
        db: SQLiteDatabase,
        id: String,
        payload: ConflictMerger.RecordFields,
        metadata: Data?
    ) throws -> FetchedApplyResult {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            if let tombstone = try SyncTracking.tombstone(db: db, entity: .record, id: id) {
                if payload.updatedAt > tombstone.deletedAt {
                    try SyncTracking.removeTombstone(db: db, entity: .record, id: id)
                    try SyncTracking.clearPending(db: db, entity: .record, id: id)
                    try upsertRecordPayload(
                        db: db,
                        id: id,
                        payload: payload,
                        metadata: metadata,
                        registerPending: false
                    )
                    try db.exec("COMMIT;")
                    return .applied
                }
                try db.exec("COMMIT;")
                return .retainedTombstone(id: id)
            }

            let local = try fetchByID(db: db, id: id)
            let pending = try SyncTracking.pending(db: db, entity: .record, id: id)

            if let local, pending?.changeType == .upsert {
                let ancestor = ancestorRecordFields(metadata: try SyncTracking.systemFields(db: db, entity: .record, id: id))
                let outcome = ConflictMerger.mergeRecord(
                    local: ConflictMerger.RecordFields(local),
                    server: payload,
                    ancestor: ancestor
                )
                switch outcome {
                case .merged(let merged):
                    let needsUpload = merged != payload
                    try upsertRecordPayload(
                        db: db,
                        id: id,
                        payload: merged,
                        metadata: metadata,
                        registerPending: needsUpload
                    )
                    if !needsUpload {
                        try SyncTracking.clearPending(db: db, entity: .record, id: id)
                    }
                    try db.exec("COMMIT;")
                    return needsUpload ? .appliedNeedsUpload(id: id) : .applied
                case .keepBoth(let server, let localDuplicate):
                    try upsertRecordPayload(
                        db: db,
                        id: id,
                        payload: server,
                        metadata: metadata,
                        registerPending: server != payload
                    )
                    if server == payload {
                        try SyncTracking.clearPending(db: db, entity: .record, id: id)
                    }
                    let duplicateID = UUID().uuidString
                    let now = currentTimeMillis()
                    var duplicate = localDuplicate
                    duplicate.createdAt = now
                    duplicate.updatedAt = now
                    // The duplicate is the visible half of the conflict pair;
                    // it uploads with the marker so every device sees it.
                    duplicate.conflictOf = id
                    try insertRecordPayload(
                        db: db,
                        id: duplicateID,
                        payload: duplicate,
                        metadata: nil,
                        registerPending: true
                    )
                    try db.exec("COMMIT;")
                    return .keepBothNeedsUpload(originalID: id, duplicateID: duplicateID)
                }
            }

            try upsertRecordPayload(
                db: db,
                id: id,
                payload: payload,
                metadata: metadata,
                registerPending: false
            )
            try SyncTracking.clearPending(db: db, entity: .record, id: id)
            try db.exec("COMMIT;")
            return .applied
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func applyFetchedProject(
        db: SQLiteDatabase,
        id: String,
        payload: ConflictMerger.ProjectFields,
        metadata: Data?
    ) throws -> FetchedApplyResult {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            if let tombstone = try SyncTracking.tombstone(db: db, entity: .project, id: id) {
                if payload.updatedAt > tombstone.deletedAt {
                    try SyncTracking.removeTombstone(db: db, entity: .project, id: id)
                    try SyncTracking.clearPending(db: db, entity: .project, id: id)
                    try upsertProjectPayload(
                        db: db,
                        id: id,
                        payload: payload,
                        metadata: metadata,
                        registerPending: false
                    )
                    try db.exec("COMMIT;")
                    return .applied
                }
                try db.exec("COMMIT;")
                return .retainedTombstone(id: id)
            }

            let local = try ProjectStore.fetchByID(db: db, id: id)
            let pending = try SyncTracking.pending(db: db, entity: .project, id: id)

            if let local, pending?.changeType == .upsert {
                let ancestor = ancestorProjectFields(metadata: try SyncTracking.systemFields(db: db, entity: .project, id: id))
                let merged = ConflictMerger.mergeProject(
                    local: ConflictMerger.ProjectFields(local),
                    server: payload,
                    ancestor: ancestor
                )
                let needsUpload = merged != payload
                try upsertProjectPayload(
                    db: db,
                    id: id,
                    payload: merged,
                    metadata: metadata,
                    registerPending: needsUpload
                )
                if !needsUpload {
                    try SyncTracking.clearPending(db: db, entity: .project, id: id)
                }
                try db.exec("COMMIT;")
                return needsUpload ? .appliedNeedsUpload(id: id) : .applied
            }

            try upsertProjectPayload(
                db: db,
                id: id,
                payload: payload,
                metadata: metadata,
                registerPending: false
            )
            try SyncTracking.clearPending(db: db, entity: .project, id: id)
            try db.exec("COMMIT;")
            return .applied
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func applyRemoteDeletion(
        db: SQLiteDatabase,
        entity: SyncEntity,
        id: String
    ) throws -> RemoteDeletionResult {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            if try SyncTracking.tombstone(db: db, entity: entity, id: id) != nil {
                try SyncTracking.removeTombstone(db: db, entity: entity, id: id)
                try SyncTracking.clearPending(db: db, entity: entity, id: id)
                try db.exec("COMMIT;")
                return .alreadyGone
            }

            let pending = try SyncTracking.pending(db: db, entity: entity, id: id)
            if pending?.changeType == .upsert {
                try db.exec("COMMIT;")
                return .retainedNeedsUpload
            }

            switch entity {
            case .record:
                try db.run("DELETE FROM record WHERE id = ?", bindings: [.text(id)])
                try db.run("DELETE FROM record_fts WHERE record_id = ?", bindings: [.text(id)])
            case .project:
                let now = currentTimeMillis()
                try db.run(
                    "UPDATE record SET project_id = NULL, updated_at = ? WHERE project_id = ?",
                    bindings: [.int64(now), .text(id)]
                )
                try db.run("DELETE FROM project WHERE id = ?", bindings: [.text(id)])
            }
            try SyncTracking.clearPending(db: db, entity: entity, id: id)
            try db.exec("COMMIT;")
            return .deleted
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func loadRecordForUpload(db: SQLiteDatabase, id: String) throws -> (Record, Data?)? {
        guard let record = try fetchByID(db: db, id: id) else { return nil }
        let metadata = try SyncTracking.systemFields(db: db, entity: .record, id: id)
        return (record, metadata)
    }

    static func loadProjectForUpload(db: SQLiteDatabase, id: String) throws -> (Project, Data?)? {
        guard let project = try ProjectStore.fetchByID(db: db, id: id) else { return nil }
        let metadata = try SyncTracking.systemFields(db: db, entity: .project, id: id)
        return (project, metadata)
    }

    static func acknowledgeUpload(
        db: SQLiteDatabase,
        entity: SyncEntity,
        id: String,
        metadata: Data
    ) throws {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try SyncTracking.saveSystemFields(db: db, entity: entity, id: id, data: metadata)
            try SyncTracking.clearPending(db: db, entity: entity, id: id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func acknowledgeDeletion(db: SQLiteDatabase, entity: SyncEntity, id: String) throws {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try SyncTracking.removeTombstone(db: db, entity: entity, id: id)
            try SyncTracking.clearPending(db: db, entity: entity, id: id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func upsertRecordPayload(
        db: SQLiteDatabase,
        id: String,
        payload: ConflictMerger.RecordFields,
        metadata: Data?,
        registerPending: Bool
    ) throws {
        if try fetchByID(db: db, id: id) == nil {
            try insertRecordPayload(
                db: db,
                id: id,
                payload: payload,
                metadata: metadata,
                registerPending: registerPending
            )
            return
        }
        try db.run(
            """
            UPDATE record SET
                content = ?, priority = ?, status = ?, project_id = ?,
                created_at = ?, updated_at = ?, resolved_at = ?, deleted_at = ?,
                conflict_of = ?, ck_system_fields = ?
            WHERE id = ?
            """,
            bindings: recordBindings(id: id, payload: payload, metadata: metadata)
        )
        try db.run(
            "UPDATE record_fts SET content = ? WHERE record_id = ?",
            bindings: [.text(payload.content), .text(id)]
        )
        if registerPending {
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
        }
    }

    static func insertRecordPayload(
        db: SQLiteDatabase,
        id: String,
        payload: ConflictMerger.RecordFields,
        metadata: Data?,
        registerPending: Bool
    ) throws {
        try db.run(
            """
            INSERT INTO record
                (id, content, priority, status, project_id, created_at, updated_at,
                 resolved_at, deleted_at, conflict_of, ck_system_fields)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(payload.content),
                .int64(Int64(payload.priority)),
                .int64(Int64(payload.status)),
                payload.projectID.map(SQLiteValue.text) ?? .null,
                .int64(payload.createdAt),
                .int64(payload.updatedAt),
                payload.resolvedAt.map(SQLiteValue.int64) ?? .null,
                payload.deletedAt.map(SQLiteValue.int64) ?? .null,
                payload.conflictOf.map(SQLiteValue.text) ?? .null,
                metadata.map(SQLiteValue.blob) ?? .null
            ]
        )
        try db.run(
            "INSERT INTO record_fts (record_id, content) VALUES (?, ?)",
            bindings: [.text(id), .text(payload.content)]
        )
        if registerPending {
            try SyncTracking.registerPending(db: db, entity: .record, id: id, changeType: .upsert)
        }
    }

    static func upsertProjectPayload(
        db: SQLiteDatabase,
        id: String,
        payload: ConflictMerger.ProjectFields,
        metadata: Data?,
        registerPending: Bool
    ) throws {
        let bindings: [SQLiteValue] = [
            .text(payload.name),
            .int64(payload.manualOrder),
            .int64(payload.createdAt),
            .int64(payload.updatedAt),
            metadata.map(SQLiteValue.blob) ?? .null,
            .text(id)
        ]
        if try ProjectStore.fetchByID(db: db, id: id) == nil {
            try db.run(
                """
                INSERT INTO project
                    (id, name, manual_order, created_at, updated_at, ck_system_fields)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(id),
                    .text(payload.name),
                    .int64(payload.manualOrder),
                    .int64(payload.createdAt),
                    .int64(payload.updatedAt),
                    metadata.map(SQLiteValue.blob) ?? .null
                ]
            )
        } else {
            try db.run(
                """
                UPDATE project SET
                    name = ?, manual_order = ?, created_at = ?, updated_at = ?,
                    ck_system_fields = ?
                WHERE id = ?
                """,
                bindings: bindings
            )
        }
        if registerPending {
            try SyncTracking.registerPending(db: db, entity: .project, id: id, changeType: .upsert)
        }
    }

    private static func recordBindings(
        id: String,
        payload: ConflictMerger.RecordFields,
        metadata: Data?
    ) -> [SQLiteValue] {
        [
            .text(payload.content),
            .int64(Int64(payload.priority)),
            .int64(Int64(payload.status)),
            payload.projectID.map(SQLiteValue.text) ?? .null,
            .int64(payload.createdAt),
            .int64(payload.updatedAt),
            payload.resolvedAt.map(SQLiteValue.int64) ?? .null,
            payload.deletedAt.map(SQLiteValue.int64) ?? .null,
            payload.conflictOf.map(SQLiteValue.text) ?? .null,
            metadata.map(SQLiteValue.blob) ?? .null,
            .text(id)
        ]
    }

    private static func ancestorRecordFields(metadata: Data?) -> ConflictMerger.RecordFields? {
        guard let metadata,
              let unpacked = CKLocalMetadata.unpack(metadata) else {
            return nil
        }
        return ConflictMerger.RecordFields.fromJSON(unpacked.ancestorJSON)
    }

    private static func ancestorProjectFields(metadata: Data?) -> ConflictMerger.ProjectFields? {
        guard let metadata,
              let unpacked = CKLocalMetadata.unpack(metadata) else {
            return nil
        }
        return ConflictMerger.ProjectFields.fromJSON(unpacked.ancestorJSON)
    }
}
