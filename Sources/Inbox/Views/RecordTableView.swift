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
/// - Enter requests Inline Edit (single selection only);
/// - ⇧↑ / ⇧↓ extend the selection over navigable rows, ⌘A selects every
///   Record row — batch actions (Space / ←→ / ⌫ / M / copy) then apply to
///   the whole selection.
///
/// All of the above only ever fire while this table view itself is first
/// responder, i.e. in Row Focus. Once Inline Edit starts, first responder
/// moves to the row's own text field editor and key events go there instead
/// — this class's keyDown is simply not invoked, so no extra "suspend"
/// bookkeeping is needed here to let text editing take over.
final class RecordTableView: NSTableView {
    /// Set by the owning view controller; called when Up is pressed on row 0.
    var onRequestReturnFocusToInput: (() -> Void)?
    /// Called with the selected Record rows when `←`/`→` is pressed.
    var onAdjustPriority: ((IndexSet, PriorityAdjustment) -> Void)?
    /// Called with the selected Record rows when Space is pressed.
    var onToggleResolve: ((IndexSet) -> Void)?
    /// Called with the focused row when Enter is pressed on a single selection.
    var onRequestBeginInlineEdit: ((Int) -> Void)?
    /// Called with the selected Record rows when `M` is pressed (PRD §8.7).
    var onRequestMoveMenu: ((IndexSet) -> Void)?
    /// Group headers are not navigable; ↑↓ skip them. Nil means every row is.
    var isNavigableRow: ((Int) -> Bool)?
    /// Right-click: Record rows get Move to; Project group headers get
    /// Rename/Delete. Nil means no menu.
    var onBuildContextMenu: ((Int) -> NSMenu?)?
    /// Called with the selected Record rows when ⌫ (Delete/Backspace) is pressed.
    var onRequestDelete: ((IndexSet) -> Void)?
    /// Called with the selected Record rows on ⌘C / Edit ▸ Copy.
    var onRequestCopy: ((IndexSet) -> Void)?

    /// ⇧↑/⇧↓ range-selection state: the fixed end (`anchor`) and the moving
    /// end (`lead`). Any plain-arrow move or click invalidates it — detected
    /// by the lead no longer being part of the current selection, plus an
    /// explicit reset in the plain-arrow paths.
    private var selectionAnchorRow: Int?
    private var selectionLeadRow: Int?

    override var mouseDownCanMoveWindow: Bool { false }

    /// Automatic row heights are measured at the width the row first had;
    /// AppKit does not re-measure on a width change, and `noteHeightOfRows`
    /// only ever grows a row (HISTORY R4), so a wrapped row kept a stale
    /// height after a resize (pixel snapshots: 3 lines in a 5-line row).
    /// A full reload re-measures at the new width in both directions; the
    /// cheap grow-only note keeps live resize fluid, the reload lands when
    /// it ends. Height-only changes must not re-enter, hence the guard.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, usesAutomaticRowHeights, numberOfRows > 0 else { return }
        if inLiveResize {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.numberOfRows))
            }
        } else {
            reloadKeepingSelection()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if usesAutomaticRowHeights, numberOfRows > 0 {
            reloadKeepingSelection()
        }
    }

    private func reloadKeepingSelection() {
        let selected = selectedRowIndexes
        reloadData()
        if !selected.isEmpty {
            selectRowIndexes(selected, byExtendingSelection: false)
        }
    }

    /// AppKit still insets the cell inside the row (~6pt) even with
    /// `.fullWidth`. Stretch to the row so the 16pt rail matches All.
    /// Re-checked 2026-08-22 on macOS 26.6: without this and the row
    /// view's `layout()` the text rail lands at 31 instead of 25.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let rowFrame = rect(ofRow: row)
        frame.origin.x = rowFrame.origin.x
        frame.size.width = rowFrame.size.width
        return frame
    }

    /// Header cells are not NSControls, so a transparent table's hitTest
    /// lands on the table itself and stock mouseDown only tries selection
    /// (which headers cannot enter). Forward the click to the header.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let row = self.row(at: local)
        if row >= 0, let header = view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupHeaderCellView {
            header.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        // Dispatch on the typed character, not the hardware keyCode: `M`
        // sits on a different physical key on Dvorak / AZERTY layouts.
        switch event.specialKey {
        case .upArrow?:
            if shift {
                extendSelection(direction: -1)
            } else if let prev = nearestNavigableRow(from: selectedRow, direction: -1) {
                resetSelectionAnchor()
                selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                scrollRowToVisible(prev)
            } else {
                onRequestReturnFocusToInput?()
            }
        case .downArrow?:
            if shift {
                extendSelection(direction: 1)
            } else if let next = nearestNavigableRow(from: selectedRow, direction: 1) {
                resetSelectionAnchor()
                selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                scrollRowToVisible(next)
            }
        case .leftArrow?:
            if !selectedNavigableRows.isEmpty, let onAdjustPriority {
                onAdjustPriority(selectedNavigableRows, .raise)
            } else {
                super.keyDown(with: event)
            }
        case .rightArrow?:
            if !selectedNavigableRows.isEmpty, let onAdjustPriority {
                onAdjustPriority(selectedNavigableRows, .lower)
            } else {
                super.keyDown(with: event)
            }
        case .carriageReturn?, .enter?:
            // Inline Edit is a single-row state; on a multi-selection Enter
            // is a no-op rather than editing an arbitrary member.
            if selectedNavigableRows.count == 1, let row = selectedNavigableRows.first, let onRequestBeginInlineEdit {
                onRequestBeginInlineEdit(row)
            } else if selectedNavigableRows.isEmpty {
                super.keyDown(with: event)
            }
        case .delete?:
            // ⌫ (Delete/Backspace) deletes the selected Records. Chosen to
            // match macOS convention: Finder, Mail, and Reminders all use ⌫
            // to delete the selected item. Row Focus is not a text-editing
            // state, so this does not conflict with character deletion —
            // during Inline Edit / Universal Input the field editor is
            // first responder and this keyDown is not invoked.
            if !selectedNavigableRows.isEmpty, let onRequestDelete {
                onRequestDelete(selectedNavigableRows)
            } else {
                super.keyDown(with: event)
            }
        default:
            keyDownCharacter(event)
        }
    }

    /// Non-special keys: Space and the Move-menu letter. ⌘-combos normally
    /// never reach keyDown (performKeyEquivalent runs first), but a ⌘M with
    /// no menu item would — keep it out of the Move menu explicitly.
    private func keyDownCharacter(_ event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " "?:
            if !selectedNavigableRows.isEmpty, let onToggleResolve {
                onToggleResolve(selectedNavigableRows)
            } else {
                super.keyDown(with: event)
            }
        case "m"? where !command:
            if !selectedNavigableRows.isEmpty, let onRequestMoveMenu {
                onRequestMoveMenu(selectedNavigableRows)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Edit ▸ Copy (⌘C) reaches here through the responder chain while the
    /// table is first responder; the Universal Input / Inline Edit field
    /// editor intercepts it first in those states.
    @objc func copy(_ sender: Any?) {
        guard !selectedNavigableRows.isEmpty else { return }
        onRequestCopy?(selectedNavigableRows)
    }

    /// Edit ▸ Select All (⌘A) in Row Focus: every Record row, skipping
    /// headers (stock selectAll would include them).
    override func selectAll(_ sender: Any?) {
        var rows = IndexSet()
        for row in 0..<numberOfRows where isNavigable(row) {
            rows.insert(row)
        }
        guard !rows.isEmpty else { return }
        resetSelectionAnchor()
        selectRowIndexes(rows, byExtendingSelection: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let row = self.row(at: location)
        guard row >= 0 else { return nil }
        // Right-click inside the current multi-selection keeps it (the menu
        // targets the whole selection); outside, it collapses to that row.
        if isNavigable(row), !selectedRowIndexes.contains(row) {
            resetSelectionAnchor()
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onBuildContextMenu?(row)
    }

    /// First Record row at or after `from` (used by Input ↓).
    func firstNavigableRow(from start: Int = 0) -> Int? {
        nearestNavigableRow(from: start - 1, direction: 1)
    }

    /// The Record rows of the current selection, in row order. Headers can't
    /// enter the selection (the delegate filters proposals), so this is
    /// normally just `selectedRowIndexes`.
    var selectedNavigableRows: IndexSet {
        IndexSet(selectedRowIndexes.filter { isNavigable($0) })
    }

    private func isNavigable(_ row: Int) -> Bool {
        isNavigableRow?(row) ?? true
    }

    // MARK: - ⇧↑/⇧↓ range selection

    private func resetSelectionAnchor() {
        selectionAnchorRow = nil
        selectionLeadRow = nil
    }

    private func extendSelection(direction: Int) {
        // (Re)derive the anchor when there is no live shift session — first
        // ⇧arrow after a click / plain move — so the range grows from the
        // currently focused row.
        if selectionAnchorRow == nil || selectionLeadRow.map({ !selectedRowIndexes.contains($0) }) ?? true {
            selectionAnchorRow = selectedRow
            selectionLeadRow = selectedRow
        }
        guard let anchor = selectionAnchorRow, anchor >= 0,
              let lead = selectionLeadRow, lead >= 0 else {
            // No selection yet: ⇧↓ behaves like ↓ into the first row.
            if direction == 1, let first = firstNavigableRow() {
                selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
                scrollRowToVisible(first)
                selectionAnchorRow = first
                selectionLeadRow = first
            }
            return
        }
        guard let newLead = nearestNavigableRow(from: lead, direction: direction) else { return }
        selectionLeadRow = newLead
        var range = IndexSet()
        for row in min(anchor, newLead)...max(anchor, newLead) where isNavigable(row) {
            range.insert(row)
        }
        selectRowIndexes(range, byExtendingSelection: false)
        scrollRowToVisible(newLead)
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

/// Row chrome that does not paint an opaque fill, so the window's
/// sidebar material shows through between records. Selection still uses
/// the stock highlight.
final class ClearTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ClearTableRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override var mouseDownCanMoveWindow: Bool { false }

    override func drawBackground(in dirtyRect: NSRect) {}

    /// AppKit insets the cell inside the row even with `.fullWidth`. Pin
    /// cells to the table's full width so the 16pt rail matches All — but
    /// keep AppKit's vertical placement: with automatic row heights the row
    /// is fitting height + intercellSpacing and the cell sits centred in it.
    /// Stretching the cell to the row height left its subviews laid out for
    /// the shorter height, so the selection showed uneven top/bottom gaps.
    override func layout() {
        super.layout()
        let width = (superview as? NSTableView)?.bounds.width ?? bounds.width
        for view in subviews where view is NSTableCellView {
            view.frame = NSRect(x: 0, y: view.frame.origin.y, width: width, height: view.frame.height)
        }
    }

    static func dequeue(in tableView: NSTableView) -> NSTableRowView {
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClearTableRowView {
            return recycled
        }
        return ClearTableRowView()
    }
}
