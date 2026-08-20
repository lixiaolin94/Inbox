import Foundation

/// Pure Row Focus inheritance rule for when a Record disappears from the
/// currently visible list (PRD §8.6, Show Resolved = Off): after Resolve
/// removes the row at `index`, focus goes to (1) whatever now occupies that
/// same index — i.e. the next Record, (2) the previous Record if there is no
/// next one, or (3) nil — meaning Universal Input — if the list is now empty.
///
/// Show Resolved = On uses the same rule, but walks the Open sequence only
/// so Focus stays in the processing stream instead of following the Record
/// into the Resolved group.
enum RowFocusInheritance {
    static func nextFocusIndex(afterRemovingRowAt index: Int, remainingCount: Int) -> Int? {
        guard remainingCount > 0 else { return nil }
        if index < remainingCount { return index }
        return remainingCount - 1
    }

    /// After Resolve: pick the next Open Record id, ignoring Resolved rows.
    /// `previousOpenIDs` is the Open sequence before the status change
    /// (including `id`); `remainingOpenIDs` is the Open sequence after.
    static func nextOpenRecordID(
        afterResolving id: String,
        previousOpenIDs: [String],
        remainingOpenIDs: [String]
    ) -> String? {
        guard let index = previousOpenIDs.firstIndex(of: id) else {
            return remainingOpenIDs.first
        }
        guard let nextIndex = nextFocusIndex(
            afterRemovingRowAt: index,
            remainingCount: remainingOpenIDs.count
        ) else {
            return nil
        }
        return remainingOpenIDs[nextIndex]
    }
}
