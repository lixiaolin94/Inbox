import AppKit

/// NSTableView subclass that owns the Row Focus keyboard model (PRD §8.3–8.6)
/// that plain NSTableView doesn't provide out of the box:
///
/// - Up on the first visible Record hands focus back to Universal Input
///   (group headers are skipped by ↑↓);
/// - Left/Right adjust Priority instead of NSTableView's default column
///   selection / horizontal scroll behavior, so they must be caught here
///   explicitly rather than falling through to `super`;
/// - Space toggles Resolve / Reopen;
/// - Enter requests Inline Edit.
///
/// All of the above only ever fire while this table view itself is first
/// responder, i.e. in Row Focus. Once Inline Edit starts, first responder
/// moves to the row's own text field editor and key events go there instead
/// — this class's keyDown is simply not invoked, so no extra "suspend"
/// bookkeeping is needed here to let text editing take over.
final class RecordTableView: NSTableView {
    /// Set by the owning view controller; called when Up is pressed on row 0.
    var onRequestReturnFocusToInput: (() -> Void)?
    /// Called with the focused row when `←`/`→` is pressed.
    var onAdjustPriority: ((Int, PriorityAdjustment) -> Void)?
    /// Called with the focused row when Space is pressed.
    var onToggleResolve: ((Int) -> Void)?
    /// Called with the focused row when Enter is pressed.
    var onRequestBeginInlineEdit: ((Int) -> Void)?
    /// Called with the focused Record row when `M` is pressed (PRD §8.7).
    var onRequestMoveMenu: ((Int) -> Void)?
    /// Group headers are not navigable; ↑↓ skip them. Nil means every row is.
    var isNavigableRow: ((Int) -> Bool)?
    /// Right-click: Record rows get Move to; Project group headers get
    /// Rename/Delete. Nil means no menu.
    var onBuildContextMenu: ((Int) -> NSMenu?)?
    /// Called with the focused Record row when ⌫ (keyCode 51) is pressed.
    var onRequestDelete: ((Int) -> Void)?
    /// Esc. Nil means the event falls through to `super`.
    var onRequestEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.upArrow:
            if let prev = nearestNavigableRow(from: selectedRow, direction: -1) {
                selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                scrollRowToVisible(prev)
            } else {
                onRequestReturnFocusToInput?()
            }
        case KeyCode.downArrow:
            if let next = nearestNavigableRow(from: selectedRow, direction: 1) {
                selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                scrollRowToVisible(next)
            }
        case KeyCode.leftArrow:
            if let row = focusedRecordRow, let onAdjustPriority {
                onAdjustPriority(row, .raise)
            } else {
                super.keyDown(with: event)
            }
        case KeyCode.rightArrow:
            if let row = focusedRecordRow, let onAdjustPriority {
                onAdjustPriority(row, .lower)
            } else {
                super.keyDown(with: event)
            }
        case KeyCode.space:
            if let row = focusedRecordRow, let onToggleResolve {
                onToggleResolve(row)
            } else {
                super.keyDown(with: event)
            }
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if let row = focusedRecordRow, let onRequestBeginInlineEdit {
                onRequestBeginInlineEdit(row)
            } else {
                super.keyDown(with: event)
            }
        case KeyCode.m:
            if let row = focusedRecordRow, let onRequestMoveMenu {
                onRequestMoveMenu(row)
            } else {
                super.keyDown(with: event)
            }
        case KeyCode.delete:
            // ⌫ (keyCode 51, Delete/Backspace) deletes the focused Record.
            // Chosen to match macOS convention: Finder, Mail, and Reminders
            // all use ⌫ to delete the selected item. Row Focus is not a
            // text-editing state, so this does not conflict with character
            // deletion — during Inline Edit / Universal Input the field
            // editor is first responder and this keyDown is not invoked.
            if let row = focusedRecordRow, let onRequestDelete {
                onRequestDelete(row)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let row = self.row(at: location)
        guard row >= 0 else { return nil }
        if isNavigable(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onBuildContextMenu?(row)
    }

    /// First Record row at or after `from` (used by Input ↓).
    func firstNavigableRow(from start: Int = 0) -> Int? {
        nearestNavigableRow(from: start - 1, direction: 1)
    }

    private var focusedRecordRow: Int? {
        let row = selectedRow
        guard row >= 0, isNavigable(row) else { return nil }
        return row
    }

    private func isNavigable(_ row: Int) -> Bool {
        isNavigableRow?(row) ?? true
    }

    /// Walk `direction` (+1 down / −1 up) from `from` until a Record row.
    /// `from` may be −1 (no selection) or a header; the start row itself is
    /// not returned.
    private func nearestNavigableRow(from fromRow: Int, direction: Int) -> Int? {
        var row = fromRow + direction
        while row >= 0 && row < numberOfRows {
            if isNavigable(row) { return row }
            row += direction
        }
        return nil
    }
}

private enum KeyCode {
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let space: UInt16 = 49
    static let m: UInt16 = 46
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
}
