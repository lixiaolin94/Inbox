import AppKit
import CloudKit
import Foundation
import os
import Security

/// CKSyncEngine coordinator. Store writes stay local-first; this type
/// subscribes to `onDidCommitChange` and applies remote events on the DB
/// serial queue. No actor — hops are explicit DispatchQueue calls.
final class InboxSyncEngine: @unchecked Sendable {
    static let containerIdentifier = "iCloud.com.xiaolin.Inbox"
    /// Which CloudKit environment this build talks to (entitlement
    /// `icloud-container-environment`, mirrored by the compilation
    /// condition project.yml sets for Release). Records synced against one
    /// environment are unknown to the other, so a switch re-uploads.
    static let environment: String = {
        #if CLOUDKIT_PRODUCTION
        return "production"
        #else
        return "development"
        #endif
    }()
    static let logger = Logger(subsystem: "com.xiaolin.Inbox", category: "sync")

    private let store: RecordStore
    private let stateURL: URL
    private let container: CKContainer
    private let proxy = DelegateProxy()
    private var engine: CKSyncEngine!

    init(store: RecordStore, stateURL: URL) {
        self.store = store
        self.stateURL = stateURL
        self.container = CKContainer(identifier: Self.containerIdentifier)
        proxy.owner = self

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: proxy
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)

        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordMapping.zone)])
        replayPendingIntoEngine()

        store.onDidCommitChange = { [weak self] changes in
            self?.enqueue(changes)
        }

        NSApplication.shared.registerForRemoteNotifications()
        Self.logger.info("sync engine started")
    }

    /// SPM naked binary, `--ui-smoke`, and anything without the CloudKit
    /// container entitlement skip this entirely (PRD §14.2, §15.2).
    static func shouldEnable(launch: LaunchConfiguration) -> Bool {
        if launch.isUISmoke { return false }
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        guard hasCloudKitContainerEntitlement() else { return false }
        return Preferences.isSyncEnabled
    }

    static func makeIfEnabled(store: RecordStore, stateURL: URL, launch: LaunchConfiguration) -> InboxSyncEngine? {
        guard shouldEnable(launch: launch) else { return nil }
        if let last = Preferences.lastSyncEnvironment, last != environment {
            // The library was last synced against the other environment:
            // its server copies are not in this one, so every row goes up
            // again (local-first, nothing is dropped). The per-environment
            // state file means no stale change tokens either.
            do {
                try store.requeueAllForSync()
                logger.info("CloudKit environment changed \(last, privacy: .public) → \(environment, privacy: .public); re-uploading the library")
            } catch {
                logger.error("re-queue after environment change failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        Preferences.lastSyncEnvironment = environment
        return InboxSyncEngine(store: store, stateURL: stateURL)
    }

    /// One state file per environment: change tokens from Development are
    /// meaningless against Production and vice versa.
    static func stateURL(databasePath: String?) -> URL {
        if let databasePath {
            return URL(fileURLWithPath: databasePath + ".ck-sync-state-\(environment)")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("ck-sync-state-\(environment).json")
    }

    static func hasCloudKitContainerEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            &error
        ) else {
            return false
        }
        let identifiers = value as? [String] ?? []
        return identifiers.contains(containerIdentifier)
    }

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func sendChanges() async throws {
        try await engine.sendChanges()
    }

    func fetchChanges() async throws {
        try await engine.fetchChanges()
    }

    // MARK: - Pending → engine

    private func enqueue(_ changes: [PendingChange]) {
        guard !changes.isEmpty else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordMapping.zone)])
        engine.state.add(pendingRecordZoneChanges: changes.map(Self.zoneChange(from:)))
    }

    private func replayPendingIntoEngine() {
        do {
            let pending = try store.pendingChanges()
            enqueue(pending)
        } catch {
            recordFailure("failed to replay pending changes: \(error.localizedDescription)")
        }
    }

    private static func zoneChange(from change: PendingChange) -> CKSyncEngine.PendingRecordZoneChange {
        let recordID = CKRecordMapping.recordID(forLocalID: change.id)
        switch change.changeType {
        case .upsert: return .saveRecord(recordID)
        case .delete: return .deleteRecord(recordID)
        }
    }

    // MARK: - Delegate handling (CKSyncEngine serial, not main, not DB queue)

    fileprivate func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persistState(update.stateSerialization)
        case .accountChange(let change):
            handleAccountChange(change)
        case .fetchedDatabaseChanges(let fetched):
            await handleFetchedDatabaseChanges(fetched)
        case .fetchedRecordZoneChanges(let fetched):
            await handleFetchedRecordZoneChanges(fetched)
        case .sentRecordZoneChanges(let sent):
            await handleSentRecordZoneChanges(sent)
        case .didFetchRecordZoneChanges(let fetched):
            // Fires after every zone fetch, changes or not — the only
            // completion event that carries an error (§15.4 diagnosable).
            if fetched.error == nil { recordSuccess() }
        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    fileprivate func nextBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.ckRecordForUpload(recordID)
        }
    }

    private func ckRecordForUpload(_ recordID: CKRecord.ID) async -> CKRecord? {
        let id = recordID.recordName
        do {
            if let pair = try await store.syncPerform({ try RecordStore.loadRecordForUpload(db: self.store.db, id: id) }) {
                return CKRecordMapping.makeRecord(from: pair.0, metadata: pair.1)
            }
            if let pair = try await store.syncPerform({ try RecordStore.loadProjectForUpload(db: self.store.db, id: id) }) {
                return CKRecordMapping.makeProject(from: pair.0, metadata: pair.1)
            }
        } catch {
            recordFailure("upload payload failed for \(id): \(error.localizedDescription)")
        }
        return nil
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            Self.logger.info("iCloud signed in; replaying pending changes")
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordMapping.zone)])
            replayPendingIntoEngine()
        case .signOut:
            // Local-first: keep the SQLite library and pending_change rows.
            Self.logger.info("iCloud signed out; local data retained")
        case .switchAccounts:
            Self.logger.info("iCloud account switched; replaying pending onto the new account")
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordMapping.zone)])
            replayPendingIntoEngine()
        @unknown default:
            break
        }
    }

    private func handleFetchedDatabaseChanges(_ fetched: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        for deletion in fetched.deletions {
            guard deletion.zoneID == CKRecordMapping.zoneID else { continue }
            Self.logger.info("InboxZone deletion reason=\(String(describing: deletion.reason), privacy: .public)")
            switch deletion.reason {
            case .deleted, .purged, .encryptedDataReset:
                // Local-first: keep user rows, drop CloudKit metadata, re-upload.
                await clearCloudKitMetadataAndRequeue()
            @unknown default:
                break
            }
        }
    }

    private func clearCloudKitMetadataAndRequeue() async {
        do {
            try await store.syncPerform {
                try RecordStore.requeueAllForSync(db: self.store.db)
            }
            replayPendingIntoEngine()
            notifyUI()
        } catch {
            recordFailure("failed to reset CloudKit metadata: \(error.localizedDescription)")
        }
    }

    private func handleFetchedRecordZoneChanges(_ fetched: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var didApply = false
        var failed = false
        for modification in fetched.modifications {
            let ckRecord = modification.record
            do {
                switch ckRecord.recordType {
                case CKRecordMapping.recordType:
                    let payload = CKRecordMapping.recordFields(from: ckRecord)
                    let metadata = CKRecordMapping.packMetadata(
                        from: ckRecord,
                        ancestorJSON: payload.jsonString()
                    )
                    let result = try await store.syncPerform {
                        try RecordStore.applyFetchedRecord(
                            db: self.store.db,
                            id: ckRecord.recordID.recordName,
                            payload: payload,
                            metadata: metadata
                        )
                    }
                    applyFetchResult(result)
                    didApply = true
                case CKRecordMapping.projectType:
                    let payload = CKRecordMapping.projectFields(from: ckRecord)
                    let metadata = CKRecordMapping.packMetadata(
                        from: ckRecord,
                        ancestorJSON: payload.jsonString()
                    )
                    let result = try await store.syncPerform {
                        try RecordStore.applyFetchedProject(
                            db: self.store.db,
                            id: ckRecord.recordID.recordName,
                            payload: payload,
                            metadata: metadata
                        )
                    }
                    applyFetchResult(result)
                    didApply = true
                default:
                    break
                }
            } catch {
                failed = true
                recordFailure("apply fetched record failed: \(error.localizedDescription)")
            }
        }

        for deletion in fetched.deletions {
            let entity: SyncEntity?
            switch deletion.recordType {
            case CKRecordMapping.recordType: entity = .record
            case CKRecordMapping.projectType: entity = .project
            default: entity = nil
            }
            guard let entity else { continue }
            do {
                let result = try await store.syncPerform {
                    try RecordStore.applyRemoteDeletion(
                        db: self.store.db,
                        entity: entity,
                        id: deletion.recordID.recordName
                    )
                }
                switch result {
                case .retainedNeedsUpload:
                    engine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(CKRecordMapping.recordID(forLocalID: deletion.recordID.recordName))
                    ])
                case .deleted, .alreadyGone:
                    break
                }
                didApply = true
            } catch {
                failed = true
                recordFailure("apply remote deletion failed: \(error.localizedDescription)")
            }
        }

        if didApply {
            notifyUI()
        }
        if !failed {
            recordSuccess()
        }
    }

    private func applyFetchResult(_ result: FetchedApplyResult) {
        switch result {
        case .applied:
            break
        case .appliedNeedsUpload(let id):
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecordMapping.recordID(forLocalID: id))])
        case .keepBothNeedsUpload(let originalID, let duplicateID):
            engine.state.add(pendingRecordZoneChanges: [
                .saveRecord(CKRecordMapping.recordID(forLocalID: originalID)),
                .saveRecord(CKRecordMapping.recordID(forLocalID: duplicateID))
            ])
        case .retainedTombstone(let id):
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecordMapping.recordID(forLocalID: id))])
        }
    }

    private func handleSentRecordZoneChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        var failed = !sent.failedRecordSaves.isEmpty || !sent.failedRecordDeletes.isEmpty
        for saved in sent.savedRecords {
            let entity: SyncEntity?
            let ancestorJSON: String
            switch saved.recordType {
            case CKRecordMapping.recordType:
                entity = .record
                ancestorJSON = CKRecordMapping.recordFields(from: saved).jsonString()
            case CKRecordMapping.projectType:
                entity = .project
                ancestorJSON = CKRecordMapping.projectFields(from: saved).jsonString()
            default:
                entity = nil
                ancestorJSON = "{}"
            }
            guard let entity else { continue }
            let metadata = CKRecordMapping.packMetadata(from: saved, ancestorJSON: ancestorJSON)
            do {
                try await store.syncPerform {
                    try RecordStore.acknowledgeUpload(
                        db: self.store.db,
                        entity: entity,
                        id: saved.recordID.recordName,
                        metadata: metadata
                    )
                }
            } catch {
                failed = true
                recordFailure("ack upload failed: \(error.localizedDescription)")
            }
        }

        for deletedID in sent.deletedRecordIDs {
            do {
                try await store.syncPerform {
                    try RecordStore.acknowledgeDeletion(db: self.store.db, entity: .record, id: deletedID.recordName)
                    try RecordStore.acknowledgeDeletion(db: self.store.db, entity: .project, id: deletedID.recordName)
                }
            } catch {
                failed = true
                recordFailure("ack delete failed: \(error.localizedDescription)")
            }
        }

        for failedSave in sent.failedRecordSaves {
            await handleFailedSave(failedSave)
        }
        if !failed {
            recordSuccess()
        }
    }

    private func handleFailedSave(_ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        let error = failed.error
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else {
                Self.logger.error("serverRecordChanged without serverRecord")
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                return
            }
            await applyServerRecord(server)
        case .unknownItem:
            // Deleted on the server while we still have a local row: drop
            // stale system fields and save as a new upload (lossless).
            let id = failed.record.recordID.recordName
            do {
                try await store.syncPerform {
                    try SyncTracking.saveSystemFields(db: self.store.db, entity: .record, id: id, data: nil)
                    try SyncTracking.saveSystemFields(db: self.store.db, entity: .project, id: id, data: nil)
                    try SyncTracking.registerPending(db: self.store.db, entity: .record, id: id, changeType: .upsert)
                }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
            } catch {
                recordFailure("unknownItem recovery failed: \(error.localizedDescription)")
            }
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure,
             .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy:
            Self.logger.info("transient save error \(error.code.rawValue); engine will retry")
        default:
            recordFailure("save failed \(error.code.rawValue): \(error.localizedDescription)")
        }
    }

    private func applyServerRecord(_ server: CKRecord) async {
        do {
            switch server.recordType {
            case CKRecordMapping.recordType:
                let payload = CKRecordMapping.recordFields(from: server)
                let metadata = CKRecordMapping.packMetadata(from: server, ancestorJSON: payload.jsonString())
                let result = try await store.syncPerform {
                    try RecordStore.applyFetchedRecord(
                        db: self.store.db,
                        id: server.recordID.recordName,
                        payload: payload,
                        metadata: metadata
                    )
                }
                applyFetchResult(result)
                notifyUI()
            case CKRecordMapping.projectType:
                let payload = CKRecordMapping.projectFields(from: server)
                let metadata = CKRecordMapping.packMetadata(from: server, ancestorJSON: payload.jsonString())
                let result = try await store.syncPerform {
                    try RecordStore.applyFetchedProject(
                        db: self.store.db,
                        id: server.recordID.recordName,
                        payload: payload,
                        metadata: metadata
                    )
                }
                applyFetchResult(result)
                notifyUI()
            default:
                break
            }
        } catch {
            recordFailure("serverRecordChanged apply failed: \(error.localizedDescription)")
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        }
    }

    private func persistState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Self.logger.error("failed to persist sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func notifyUI() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .inboxDidApplyRemoteChanges, object: nil)
        }
    }

    // MARK: - Status (PRD §15.2, §15.4)

    private func recordSuccess() {
        Preferences.lastSyncSucceededAt = Date()
        Preferences.lastSyncError = nil
        Preferences.lastSyncErrorAt = nil
        postStatusChange()
    }

    /// Terminal failures only. Transient save errors the engine retries
    /// stay on the info log so a short outage never reads as a problem.
    private func recordFailure(_ message: String) {
        Self.logger.error("\(message, privacy: .public)")
        Preferences.lastSyncError = message
        Preferences.lastSyncErrorAt = Date()
        postStatusChange()
    }

    private func postStatusChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .inboxSyncStatusDidChange, object: nil)
        }
    }
}

/// CKSyncEngineDelegate is Sendable and its methods are async; the proxy
/// forwards to InboxSyncEngine without introducing an actor.
private final class DelegateProxy: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: InboxSyncEngine?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handleEvent(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextBatch(context, syncEngine: syncEngine)
    }
}
