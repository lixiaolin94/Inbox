#if DEBUG
import AppKit
import CloudKit
import Foundation

/// Headless CloudKit e2e probe driven by `--sync-probe`.
///
/// Two verbs plus distinct `--db-path` values simulate two devices on one
/// Mac. Exit codes: 0 success, 1 timeout/failure, 2 no iCloud account.
enum SyncProbeRunner {
    static func start(
        store: RecordStore,
        engine: InboxSyncEngine?,
        configuration: LaunchConfiguration
    ) {
        NSApp.setActivationPolicy(.accessory)
        Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
            Task {
                await run(store: store, engine: engine, configuration: configuration)
            }
        }
    }

    private static func run(
        store: RecordStore,
        engine: InboxSyncEngine?,
        configuration: LaunchConfiguration
    ) async {
        setbuf(stdout, nil)
        guard let engine else {
            writeLine("SYNC-PROBE NO_ACCOUNT")
            exit(2)
        }
        let status = await engine.accountStatus()
        guard status == .available else {
            writeLine("SYNC-PROBE NO_ACCOUNT")
            exit(2)
        }

        guard let verb = configuration.syncProbe else {
            writeLine("SYNC-PROBE FAIL: missing verb")
            exit(1)
        }
        let content = configuration.probeContent ?? ""
        guard !content.isEmpty else {
            writeLine("SYNC-PROBE FAIL: missing --content")
            exit(1)
        }

        switch verb {
        case .create:
            await runCreate(store: store, engine: engine, content: content)
        case .expect:
            await runExpect(
                store: store,
                engine: engine,
                content: content,
                timeout: configuration.probeTimeout
            )
        }
    }

    private static func runCreate(store: RecordStore, engine: InboxSyncEngine, content: String) async {
        do {
            let record: Record = try await withCheckedThrowingContinuation { continuation in
                store.createRecord(content: content, projectID: nil) { result in
                    continuation.resume(with: result)
                }
            }
            try await sendChangesRetrying(engine)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let pending = try store.pendingChanges()
                let stillPending = pending.contains { $0.entity == .record && $0.id == record.id }
                let metadata = try store.ckSystemFields(entity: .record, id: record.id)
                if !stillPending, metadata != nil {
                    writeLine("SYNC-PROBE UPLOADED")
                    exit(0)
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            writeLine("SYNC-PROBE FAIL: upload not confirmed")
            exit(1)
        } catch {
            fail(error)
        }
    }

    private static func runExpect(
        store: RecordStore,
        engine: InboxSyncEngine,
        content: String,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while Date() < deadline {
                try await fetchChangesRetrying(engine)
                if try store.recordWithExactContent(content) != nil {
                    writeLine("SYNC-PROBE FOUND")
                    exit(0)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            writeLine("SYNC-PROBE FAIL: timed out waiting for content")
            exit(1)
        } catch {
            fail(error)
        }
    }

    private static func sendChangesRetrying(_ engine: InboxSyncEngine) async throws {
        try await retryingCloudKit {
            try await engine.sendChanges()
        }
    }

    private static func fetchChangesRetrying(_ engine: InboxSyncEngine) async throws {
        try await retryingCloudKit {
            try await engine.fetchChanges()
        }
    }

    /// CKError 15/2000 (serverRejectedRequest / internal) is a common first-use
    /// hiccup while the development container comes up; retry a few times.
    private static func retryingCloudKit(_ body: () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 1...6 {
            do {
                try await body()
                return
            } catch {
                lastError = error
                if isNoAccount(error) { throw error }
                guard isRetryable(error), attempt < 6 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        if let lastError { throw lastError }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        let code = (error as? CKError)?.code
        return code == .serverRejectedRequest
            || code == .serviceUnavailable
            || code == .requestRateLimited
            || code == .zoneBusy
            || code == .networkFailure
            || code == .networkUnavailable
    }

    private static func isNoAccount(_ error: Error) -> Bool {
        let code = (error as? CKError)?.code
        return code == .notAuthenticated || code == .accountTemporarilyUnavailable
    }

    private static func fail(_ error: Error) -> Never {
        if isNoAccount(error) {
            writeLine("SYNC-PROBE NO_ACCOUNT")
            exit(2)
        }
        let ns = error as NSError
        writeLine("SYNC-PROBE FAIL: \(ns.domain) \(ns.code) \(ns.localizedDescription) userInfo=\(ns.userInfo)")
        exit(1)
    }

    private static func writeLine(_ line: String) {
        fputs(line + "\n", stdout)
        fflush(stdout)
    }
}
#endif
