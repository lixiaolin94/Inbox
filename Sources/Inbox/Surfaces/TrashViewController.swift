import AppKit

/// Trash secondary surface (PRD §12): restore or permanently delete, then
/// Back to the main surface. No Universal Input, Scope Bar, or sort.
final class TrashViewController: NSViewController {
    var onClose: (() -> Void)?

    private let store: RecordStore
    private let tableView = RecordTableView()
    private let scrollView = OverlayScrollView()
    private let backChip = ScopeChipButton(title: "Back")
    private let restoreButton = ScopeChipButton(title: "")
    private let deletePermanentlyButton = ScopeChipButton(title: "")
    private lazy var listDissolve = EdgeDissolve(scrollView: scrollView, topBar: Theme.Size.scopeBarHeight, bottomBar: Theme.Size.utilityBarHeight)

    private var records: [Record] = []
    private var projects: [Project] = []
    private var rows: [ListRow] = []

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TrashRecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("TrashGroupHeader")

    init(store: RecordStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Same undo stack as the main surface so ⌘Z still undoes Move to Trash
    /// while this view is first-responder (via the child-VC responder chain).
    override var undoManager: UndoManager? {
        parent?.undoManager
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpTable()
        setUpLayout()
        updateActionButtons()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        listDissolve.update()
    }

    func reload(projects: [Project]) {
        self.projects = projects
        let selectedID = ListRowIndex.record(atTableRow: tableView.selectedRow, in: rows)?.id
        store.listTrashed { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let records):
                self.records = records
                let selectedIDs = self.tableView.selectedNavigableRows.compactMap {
                    ListRowIndex.record(atTableRow: $0, in: self.rows)?.id
                }
                self.rebuildRowsAndReload()
                var keep = IndexSet()
                for id in selectedIDs {
                    if let row = ListRowIndex.tableRow(forRecordID: id, in: self.rows) {
                        keep.insert(row)
                    }
                }
                if keep.isEmpty, let selectedID, let row = ListRowIndex.tableRow(forRecordID: selectedID, in: self.rows) {
                    keep.insert(row)
                }
                if !keep.isEmpty {
                    self.tableView.selectRowIndexes(keep, byExtendingSelection: false)
                }
                self.updateActionButtons()
                if !self.view.isHidden {
                    self.takeFocus()
                }
            case .failure(let error):
                Dialogs.persistenceFailure(error)
            }
        }
    }

    func takeFocus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, let row = tableView.firstNavigableRow() {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: - Set up

    private func setUpTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        // Same row metrics as the main list (heights from the same cell
        // measurement, same gap) so the selection block carries the same
        // air (ui.md §6).
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Preferences.recordRowMinHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Theme.Spacing.sm)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.isNavigableRow = { [weak self] row in
            guard let self else { return false }
            return ListRowIndex.record(atTableRow: row, in: self.rows) != nil
        }
        tableView.onBuildContextMenu = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.onRequestDelete = { [weak self] rows in
            self?.confirmPermanentDelete(records: self?.records(atRows: rows) ?? [])
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        // Header and action bars overlay the list's ends, as on the main
        // surface.
        let barInsets = NSEdgeInsets(top: Theme.Size.scopeBarHeight, left: 0, bottom: Theme.Size.utilityBarHeight, right: 0)
        scrollView.contentInsets = barInsets
        scrollView.scrollerInsets = barInsets
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        tableView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setUpLayout() {
        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        // Back sits where "All" sits on the main surface, but plain: it is
        // a way out, not an action, so it carries no fill.
        backChip.style = .plain
        backChip.symbolName = "chevron.left"
        backChip.toolTip = "Back to Inbox (esc)"
        backChip.setAccessibilityLabel("Back to Inbox")
        backChip.onClick = { [weak self] in self?.goBack() }
        backChip.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(backChip)

        // The surface title sits where a window title would — centred in
        // the (transparent) titlebar zone above the safe area — so the
        // immersive chrome stays and the surface is still named.
        let titleLabel = WindowTitleLabel(labelWithString: "Trash")
        titleLabel.font = Theme.Typography.windowTitle
        titleLabel.textColor = Theme.Ink.secondary
        titleLabel.refusesFirstResponder = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        let titleZone = NSLayoutGuide()
        view.addLayoutGuide(titleZone)

        restoreButton.style = .grouped
        restoreButton.iconOnly = true
        restoreButton.symbolName = "arrow.uturn.backward"
        restoreButton.toolTip = "Restore"
        restoreButton.setAccessibilityLabel("Restore")
        restoreButton.onClick = { [weak self] in self?.restoreSelected() }
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        deletePermanentlyButton.style = .grouped
        deletePermanentlyButton.iconOnly = true
        deletePermanentlyButton.symbolName = "xmark.bin"
        deletePermanentlyButton.toolTip = "Delete Permanently"
        deletePermanentlyButton.setAccessibilityLabel("Delete Permanently")
        deletePermanentlyButton.onClick = { [weak self] in self?.deleteSelectedPermanently() }
        deletePermanentlyButton.translatesAutoresizingMaskIntoConstraints = false

        // No key hints here on purpose: Restore is mouse-only (button or
        // context menu) and ⌫ asks for confirmation — Trash interactions
        // are meant to cost more than the main surface's.
        // 实验（未提交）：与主表面同构的玻璃胶囊 ButtonGroup。
        let trashGroup = NSStackView()
        trashGroup.orientation = .horizontal
        trashGroup.alignment = .centerY
        trashGroup.spacing = Theme.Spacing.xs
        trashGroup.translatesAutoresizingMaskIntoConstraints = false
        trashGroup.addArrangedSubview(restoreButton)
        trashGroup.addArrangedSubview(deletePermanentlyButton)

        let actionGroup = GlassCapsuleView()
        actionGroup.prefersClearGlass = true
        actionGroup.tintColor = NSColor.black.withAlphaComponent(0.4)
        actionGroup.translatesAutoresizingMaskIntoConstraints = false
        actionGroup.contentView.addSubview(trashGroup)

        let actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(actionGroup)

        // List first, bars on top: both are transparent overlays over the
        // list's ends (ui.md §4).
        view.addSubview(scrollView)
        view.addSubview(headerBar)
        view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            // 实验（未提交）：toolbar 撑高了 safe area，Back 栏与列表改锚窗口
            // 顶固定 44（标题仍留在 toolbar 区、与红绿灯对齐）。
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Theme.Size.scopeBarHeight),

            // 4pt left of the rail so the chevron's ink lands on the list
            // text rail (optical, like listTextNudge).
            backChip.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: Theme.Size.windowInset - Theme.Spacing.xs),
            backChip.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            titleZone.topAnchor.constraint(equalTo: view.topAnchor),
            titleZone.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titleZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: titleZone.centerXAnchor),
            // 实验（未提交）：unified toolbar 里红绿灯不在区域几何中心（其
            // 中心距窗顶 ~26pt），标题 centerY 直接钉这条线。
            titleLabel.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 26),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: Theme.Size.utilityBarHeight),

            actionGroup.widthAnchor.constraint(equalTo: trashGroup.widthAnchor, constant: 8),
            actionGroup.heightAnchor.constraint(equalToConstant: Theme.Size.chipHeight + 8),
            trashGroup.centerXAnchor.constraint(equalTo: actionGroup.centerXAnchor),
            trashGroup.centerYAnchor.constraint(equalTo: actionGroup.centerYAnchor),

            actionGroup.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: Theme.Size.windowInset),
            actionGroup.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: -Theme.Size.windowInset)
        ])
    }

    // MARK: - Actions

    private func goBack() {
        onClose?()
    }

    @objc private func restoreSelected() {
        restore(records(atRows: tableView.selectedNavigableRows))
    }

    @objc private func deleteSelectedPermanently() {
        confirmPermanentDelete(records: records(atRows: tableView.selectedNavigableRows))
    }

    private func restore(_ targets: [Record]) {
        let ids = targets.map(\.id)
        guard !ids.isEmpty else { return }
        RecordStore.batch(ids: ids, operation: { id, done in
            store.restoreFromTrash(id: id) { done($0.map { _ in () }) }
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
                return
            }
            self.removeRecordsFromList(ids: ids)
        }
    }

    private func confirmPermanentDelete(records targets: [Record]) {
        guard !targets.isEmpty else { return }
        let confirmed = Dialogs.confirmPermanentDelete(targets)
        takeFocus()
        guard confirmed else { return }

        let ids = targets.map(\.id)
        RecordStore.batch(ids: ids, operation: { id, done in
            store.permanentlyDelete(id: id, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
                return
            }
            self.removeRecordsFromList(ids: ids)
        }
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        let selected = tableView.selectedNavigableRows
        let targets: [Record]
        if selected.contains(row) {
            targets = records(atRows: selected)
        } else if let record = ListRowIndex.record(atTableRow: row, in: rows) {
            targets = [record]
        } else {
            return nil
        }
        let menu = NSMenu()
        let restoreTitle = targets.count == 1 ? "Restore" : "Restore \(targets.count) Records"
        let restoreItem = NSMenuItem(title: restoreTitle, action: #selector(restoreFromMenu(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.representedObject = targets.map(\.id)
        let deleteTitle = targets.count == 1 ? "Delete Permanently" : "Delete \(targets.count) Permanently"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = targets.map(\.id)
        menu.addItem(restoreItem)
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func restoreFromMenu(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        restore(records.filter { ids.contains($0.id) })
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        confirmPermanentDelete(records: records.filter { ids.contains($0.id) })
    }

    // MARK: - List

    private func rebuildRowsAndReload() {
        rows = TrashRows.build(records: records, projects: projects)
        tableView.reloadData()
    }

    private func removeRecordsFromList(ids: [String]) {
        let idSet = Set(ids)
        let previousVisibleIDs = ListRowIndex.visibleRecords(in: rows).map(\.id)
        records.removeAll { idSet.contains($0.id) }
        rebuildRowsAndReload()
        updateActionButtons()
        inheritFocus(removedIDs: ids, previousVisibleIDs: previousVisibleIDs)
    }

    private func inheritFocus(removedIDs: [String], previousVisibleIDs: [String]) {
        let remaining = ListRowIndex.visibleRecords(in: rows)
        let firstRemoved = previousVisibleIDs.firstIndex { removedIDs.contains($0) }
        guard let index = firstRemoved else {
            takeFocus()
            return
        }
        if let nextIndex = RowFocusInheritance.nextFocusIndex(
            afterRemovingRowAt: index,
            remainingCount: remaining.count
        ), let row = ListRowIndex.tableRow(forRecordID: remaining[nextIndex].id, in: rows) {
            returnFocusToRow(row)
        } else {
            tableView.deselectAll(nil)
            updateActionButtons()
            takeFocus()
        }
    }

    private func returnFocusToRow(_ row: Int) {
        guard let window = view.window, ListRowIndex.record(atTableRow: row, in: rows) != nil else {
            takeFocus()
            return
        }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateActionButtons()
    }

    private func records(atRows rowIndexes: IndexSet) -> [Record] {
        rowIndexes.compactMap { ListRowIndex.record(atTableRow: $0, in: rows) }
    }

    private func updateActionButtons() {
        let enabled = !records(atRows: tableView.selectedNavigableRows).isEmpty
        restoreButton.isEnabled = enabled
        deletePermanentlyButton.isEnabled = enabled
    }

}

extension TrashViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClearTableRowView.dequeue(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .groupHeader(_, let title, _):
            let cell = tableView.makeView(withIdentifier: Self.headerCellIdentifier, owner: self) as? GroupHeaderCellView
                ?? GroupHeaderCellView(identifier: Self.headerCellIdentifier)
            cell.configure(title: title, isCollapsed: false, showsDisclosure: false)
            cell.onToggle = nil
            cell.onBuildMenu = nil
            return cell
        case .record(let record):
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? RecordCellView
                ?? RecordCellView(identifier: Self.cellIdentifier)
            cell.configure(with: record, style: .trash)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .groupHeader: return Theme.Size.groupHeaderHeight
        case .record(let record): return RecordCellView.displayHeight(for: record, style: .trash, tableWidth: tableView.bounds.width)
        }
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { ListRowIndex.record(atTableRow: $0, in: rows) != nil })
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    var smokeAllowsMultipleSelection: Bool { tableView.allowsMultipleSelection }
    var smokeTitleFrame: NSRect? { view.subviews.first { $0 is WindowTitleLabel }?.frame }
    var smokeScrollInsets: NSEdgeInsets { scrollView.contentInsets }
    var smokeActionChips: [ScopeChipButton] { [restoreButton, deletePermanentlyButton] }
    var smokeBackChip: ScopeChipButton { backChip }
    /// Height of the first record row (row rect, gap included) as laid out.
    var smokeRowHeight: CGFloat? {
        tableView.layoutSubtreeIfNeeded()
        guard let row = tableView.firstNavigableRow() else { return nil }
        return tableView.rect(ofRow: row).height
    }
    var smokeTableIsFirstResponder: Bool { view.window?.firstResponder === tableView }
}

/// A label in the titlebar zone must not swallow the drag that moves the
/// window there. Shared by Trash and the Settings window.
final class WindowTitleLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}
