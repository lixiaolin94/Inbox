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

    func smokeWrapMetrics(forRecordID id: String) -> String? {
        guard let row = tableRow(forRecordID: id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecordCellView else { return nil }
        return String(format: "row %.1f ", tableView.rect(ofRow: row).height) + cell.smokeWrapMetrics
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
    var smokeDissolveDebug: String {
        let clip = scrollView.contentView
        let doc = scrollView.documentView?.frame.height ?? -1
        return String(format: "clip y %.1f h %.1f doc %.1f insets t %.0f b %.0f top %d bottom %d",
                      clip.bounds.origin.y, clip.bounds.height, doc,
                      scrollView.contentInsets.top, scrollView.contentInsets.bottom,
                      listDissolve.isTopActive ? 1 : 0, listDissolve.isBottomActive ? 1 : 0)
    }

    func smokeFlashScrollers() { scrollView.flashScrollers() }

    var smokeScrollFrame: NSRect { scrollView.frame }
    var smokeScrollInsets: NSEdgeInsets { scrollView.contentInsets }
    var smokeScrollerInsets: NSEdgeInsets { scrollView.scrollerInsets }
    var smokeHasDissolveMask: Bool { scrollView.layer?.mask != nil }
    var smokeDissolveState: (topActive: Bool, bottomActive: Bool) {
        (listDissolve.isTopActive, listDissolve.isBottomActive)
    }

    /// How far the record's row sits inside the scroll view's edges: from
    /// the top edge down to the row's top, and from the bottom edge up to
    /// the row's bottom. At least the matching content inset means the
    /// row is clear of the bar overlaying that edge.
    func smokeRowClearance(forRecordID id: String) -> (top: CGFloat, bottom: CGFloat)? {
        guard let row = tableRow(forRecordID: id) else { return nil }
        let frame = tableView.convert(tableView.rect(ofRow: row), to: scrollView)
        return (scrollView.bounds.maxY - frame.maxY, frame.minY - scrollView.bounds.minY)
    }

    var smokeTrashScrollInsets: NSEdgeInsets { trashViewController.smokeScrollInsets }
    var smokeTrashAllowsMultipleSelection: Bool { trashViewController.smokeAllowsMultipleSelection }
    var smokeTrashActionChips: [ScopeChipButton] { trashViewController.smokeActionChips }

    // MARK: Utility bar

    var smokeResolvedChip: ScopeChipButton { resolvedChip }
    var smokeSortChip: ScopeChipButton { sortChip }
    var smokeTrashChip: ScopeChipButton { trashButton }
    var smokeUtilityBarFrame: NSRect { utilityBar.frame }

    func smokeUtilityControlFrame(_ control: NSView) -> NSRect {
        control.convert(control.bounds, to: mainSurface)
    }

    var smokeFunctionGroupMaxX: CGFloat { smokeUtilityControlFrame(functionGroup).maxX }
    /// "key action" per hint, empty while the bar is hidden.
    var smokeHintTexts: [String] { hintBar.isHidden ? [] : hintBar.hintTexts }
    var smokeHintBarFrame: NSRect? { hintBar.isHidden ? nil : smokeUtilityControlFrame(hintBar) }
    /// Width of the tier currently loaded — the shown one, or the smallest
    /// tried when hidden.
    var smokeHintBarFittingWidth: CGFloat { hintBar.fittingSize.width }
    var smokeTrashHintTexts: [String] { trashViewController.smokeHintTexts }

    /// Whether a click in the middle of the hint bar would land on it.
    var smokeHintBarTakesMouse: Bool {
        guard let frame = smokeHintBarFrame else { return false }
        let hit = utilityBar.hitTest(NSPoint(x: frame.midX, y: frame.midY))
        return hit?.isDescendant(of: hintBar) ?? false
    }

    // MARK: Pixel alignment (window coordinates)

    var smokeChromeFramesInWindow: [(label: String, frame: NSRect)] {
        let chrome: [(String, NSView)] = [
            ("input", universalInput), ("scope bar", scopeBar), ("list", scrollView),
            ("utility bar", utilityBar)
        ]
        return chrome.map { (label: $0.0, frame: $0.1.convert($0.1.bounds, to: nil)) }
    }

    /// Every chip on both rails: Scope chips, "+", Resolved / Sort / Trash.
    var smokeChipFramesInWindow: [(label: String, frame: NSRect)] {
        let utility: [(String, ScopeChipButton)] = [("resolved", resolvedChip), ("sort", sortChip), ("trash", trashButton)]
        return scopeBar.smokeChipFrames(in: nil)
            + [(label: "add", frame: scopeBar.smokeAddButtonFrame(in: nil))]
            + utility.map { (label: "\($0.0) chip", frame: $0.1.convert($0.1.bounds, to: nil)) }
    }

    // MARK: Conflicts (PRD §15.3)

    var smokeConflictsChip: ScopeChipButton { conflictsChip }

    /// Same path as clicking the chip.
    func smokeClickConflictsChip() {
        conflictsChip.onClick?()
    }

    func smokeIsConflictBadgeShown(forRecordID id: String) -> Bool {
        guard let row = tableRow(forRecordID: id) else { return false }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? RecordCellView else { return false }
        return cell.smokeShowsConflictBadge
    }

    /// Top-level titles of the menu a right-click on the row would build.
    func smokeContextMenuTitles(forRecordID id: String) -> [String]? {
        guard let row = tableRow(forRecordID: id) else { return nil }
        return contextMenu(forRow: row)?.items.map(\.title)
    }

    private func smokeResolveConflictMenu(forRecordID id: String) -> NSMenu? {
        guard let row = tableRow(forRecordID: id) else { return nil }
        return contextMenu(forRow: row)?.items.first { $0.title == "Resolve Conflict" }?.submenu
    }

    func smokeResolveConflictMenuTitles(forRecordID id: String) -> [String]? {
        smokeResolveConflictMenu(forRecordID: id)?.items.map(\.title)
    }

    /// Same path as picking the item: the menu the row's right-click builds,
    /// then that item's action. False when the row offers no such item.
    func smokeResolveConflict(id: String, resolution: ConflictResolution) -> Bool {
        guard let item = smokeResolveConflictMenu(forRecordID: id)?.items.first(where: { $0.title == resolution.menuTitle }),
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    var smokeIsShowingTrash: Bool { isShowingTrash }
    var smokeTrashTableIsFirstResponder: Bool { trashViewController.smokeTableIsFirstResponder }

    /// Same path as clicking the Trash chip.
    func smokeOpenTrash() {
        trashButton.onClick?()
    }

    /// The two state-changing hooks: the same paths a click and a menu
    /// pick take (the chip's `onClick`, the menu item's action).
    func smokeClickResolved() {
        resolvedChip.onClick?()
    }

    /// Same path as clicking the sort chip.
    func smokeToggleSort() {
        toggleSort()
    }

    /// Programmatic Move through the same path the context menu and drag use.
    func smokeMoveRecords(ids: [String], to projectID: String?) {
        moveRecords(ids: ids, to: projectID)
    }

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
