#if DEBUG
import AppKit

/// Narrow read-only hooks for `UISmokeRunner`. Not a public API; every
/// UI-behaviour change must extend the smoke assertions (SPEC §8).
extension MainViewController {
    var smokeInputString: String { inputField.stringValue }
    var smokeVisibleRecords: [Record] { visibleRecords() }
    var smokeSelectedRecord: Record? { record(atTableRow: tableView.selectedRow) }
    var smokeSelectedRecords: [Record] { records(atTableRows: tableView.selectedNavigableRows) }

    func smokeIsInputFirstResponder() -> Bool {
        guard let window = view.window else { return false }
        let responder = window.firstResponder
        return responder === inputField || responder === inputField.currentEditor()
    }

    func smokeIsTableFirstResponder() -> Bool {
        view.window?.firstResponder === tableView
    }

    var smokeOfflineNoticeVisible: Bool { !offlineNoticeLabel.isHidden }

    func smokeIsEditingRecord(id: String) -> Bool {
        guard let row = editingRowIndex else { return false }
        return record(atTableRow: row)?.id == id
    }

    func smokeRowHeight(forRecordID id: String) -> CGFloat? {
        guard let row = tableRow(forRecordID: id) else { return nil }
        tableView.scrollRowToVisible(row)
        _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        tableView.layoutSubtreeIfNeeded()
        return tableView.rect(ofRow: row).height
    }

    var smokeInputFrame: NSRect { universalInput.frame }
    var smokeInputPlaceholder: String { inputField.placeholderString ?? "" }
    var smokeScopeBarHeight: CGFloat { scopeBar.frame.height }
    var smokeScopeBarFrame: NSRect { scopeBar.frame }
    var smokeScopeBarScrollFrame: NSRect {
        scopeBar.convert(scopeBar.smokeScrollFrame, to: mainSurface)
    }
    var smokeAllChipFrame: NSRect? { scopeBar.smokeAllChipFrame(in: mainSurface) }
    var smokeAllChipFrameInWindow: NSRect? { scopeBar.smokeAllChipFrame(in: nil) }
    var smokeAllTitleMinX: CGFloat? { scopeBar.smokeAllTitleMinX(in: mainSurface) }
    var smokeAddButtonFrame: NSRect { scopeBar.smokeAddButtonFrame(in: mainSurface) }
    var smokeSelectedScopeChipTextColor: NSColor? { scopeBar.smokeSelectedChipForegroundColor() }
    var smokeSelectedScopeChipFillColor: CGColor? { scopeBar.smokeSelectedChipFillColor() }
    var smokeScopeChipUsesGlass: Bool { scopeBar.smokeChipUsesGlass() }
    var smokeIdleChipBorderColor: CGColor? { scopeBar.smokeIdleChipBorderColor() }
    var smokeIdleChipBorderWidth: CGFloat { scopeBar.smokeIdleChipBorderWidth }
    var smokeListTopGap: CGFloat { scopeBar.frame.minY - scrollView.frame.maxY }
    var smokeTrashAllowsMultipleSelection: Bool { trashViewController.smokeAllowsMultipleSelection }

    private func smokeFirstGroupHeaderCell() -> GroupHeaderCellView? {
        for row in 0..<tableView.numberOfRows {
            guard case .groupHeader = rows[row] else { continue }
            tableView.scrollRowToVisible(row)
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? GroupHeaderCellView
            tableView.layoutSubtreeIfNeeded()
            return cell
        }
        return nil
    }

    var smokeFirstGroupHeaderTitleMinX: CGFloat? {
        smokeFirstGroupHeaderCell()?.smokeTitleMinX(in: mainSurface)
    }

    var smokeFirstGroupHeaderDisclosureMinX: CGFloat? {
        smokeFirstGroupHeaderCell()?.smokeDisclosureMinX(in: mainSurface)
    }

    private func smokeFirstRecordCell() -> RecordCellView? {
        for row in 0..<tableView.numberOfRows {
            guard case .record = rows[row] else { continue }
            tableView.scrollRowToVisible(row)
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? RecordCellView
            tableView.layoutSubtreeIfNeeded()
            return cell
        }
        return nil
    }

    var smokeFirstRecordPriorityMinX: CGFloat? {
        smokeFirstRecordCell()?.smokePriorityMinX(in: mainSurface)
    }

    var smokeFirstRecordTimeTrailingGap: CGFloat? {
        guard let cell = smokeFirstRecordCell() else { return nil }
        return mainSurface.bounds.width - cell.smokeTimeMaxX(in: mainSurface)
    }

    var smokeFirstGroupDisclosureTrailingGap: CGFloat? {
        guard let cell = smokeFirstGroupHeaderCell() else { return nil }
        return mainSurface.bounds.width - cell.smokeDisclosureMaxX(in: mainSurface)
    }

    var smokeHasInboxGroupHeader: Bool {
        rows.contains { $0.groupID == .inbox }
    }
}
#endif
