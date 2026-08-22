import AppKit

/// Trash secondary surface (PRD §12): restore or permanently delete, then
/// Back to the main surface. No Universal Input, Scope Bar, or sort.
final class TrashViewController: NSViewController {
    var onClose: (() -> Void)?

    private let store: RecordStore
    private let tableView = RecordTableView()
    private let scrollView = NSScrollView()
    private let restoreButton = ScopeChipButton(title: "Restore")
    private let deletePermanentlyButton = ScopeChipButton(title: "Delete Permanently")

    private var records: [Record] = []
    private var projects: [Project] = []
    private var rows: [ListRow] = []

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TrashRecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("TrashGroupHeader")
    private static var rowHeight: CGFloat { max(32, Preferences.recordRowMinHeight - 4) }
    private static let headerRowHeight: CGFloat = 28

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
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        tableView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setUpLayout() {
        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NSButton(title: "← Trash", target: self, action: #selector(goBack))
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 13, weight: .semibold)
        backButton.setAccessibilityLabel("Back to Inbox")
        backButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(backButton)

        restoreButton.onClick = { [weak self] in self?.restoreSelected() }
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        deletePermanentlyButton.onClick = { [weak self] in self?.deleteSelectedPermanently() }
        deletePermanentlyButton.translatesAutoresizingMaskIntoConstraints = false

        let actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(restoreButton)
        actionBar.addSubview(deletePermanentlyButton)

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerBar)
        view.addSubview(topSeparator)
        view.addSubview(scrollView)
        view.addSubview(bottomSeparator)
        view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 36),

            backButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            topSeparator.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            actionBar.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            restoreButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: LayoutChrome.contentInset),
            restoreButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            deletePermanentlyButton.leadingAnchor.constraint(equalTo: restoreButton.trailingAnchor, constant: LayoutChrome.chipSpacing),
            deletePermanentlyButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func goBack() {
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
        case .groupHeader: return Self.headerRowHeight
        case .record: return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { ListRowIndex.record(atTableRow: $0, in: rows) != nil })
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    var smokeAllowsMultipleSelection: Bool { tableView.allowsMultipleSelection }
    var smokeActionChips: [ScopeChipButton] { [restoreButton, deletePermanentlyButton] }
    var smokeTableIsFirstResponder: Bool { view.window?.firstResponder === tableView }
}
