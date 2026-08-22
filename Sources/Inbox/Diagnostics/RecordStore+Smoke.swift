#if DEBUG
import Foundation

/// `--ui-smoke` only. A conflict pair normally comes out of `ConflictMerger`
/// during a CloudKit fetch; stamping `conflict_of` directly is the only way
/// the smoke can manufacture one without an account. No `pending_change` —
/// nothing syncs in the smoke.
extension RecordStore {
    func smokeMarkAsConflictDuplicate(
        id: String,
        of originalID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [db] in
            let result = Result {
                try db.run(
                    "UPDATE record SET conflict_of = ?, updated_at = ? WHERE id = ?",
                    bindings: [.text(originalID), .int64(Self.currentTimeMillis()), .text(id)]
                )
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
#endif
