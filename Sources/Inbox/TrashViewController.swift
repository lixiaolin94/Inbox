import AppKit

/// Trash secondary surface (PRD §12): restore or permanently delete, then
/// Back to the main surface. No Universal Input, Scope Bar, or sort.
final class TrashViewController: NSViewController {
    var onClose: (() -> Void)?

    private let store: RecordStore
    private let tableView = RecordTableView()
    private let scrollView = NSScrollView()
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let deletePermanentlyButton = NSButton(title: "Delete Permanently", target: nil, action: nil)

    private var records: [Record] = []
    private var projects: [Project] = []
    private var rows: [ListRow] = []

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TrashRecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("TrashGroupHeader")
    private static let rowHeight: CGFloat = 28
    private static let headerRowHeight: CGFloat = 24

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
                self.rebuildRowsAndReload()
                if let selectedID, let row = ListRowIndex.tableRow(forRecordID: selectedID, in: self.rows) {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.updateActionButtons()
                if !self.view.isHidden {
                    self.takeFocus()
                }
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
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
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
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
        tableView.onRequestDelete = { [weak self] row in
            self?.confirmPermanentDelete(atRow: row)
        }
        tableView.onRequestEscape = { [weak self] in
            self?.onClose?()
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setUpLayout() {
        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NSButton(title: "← Trash", target: self, action: #selector(goBack))
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 13, weight: .semibold)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(backButton)

        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.font = .systemFont(ofSize: 11)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        deletePermanentlyButton.bezelStyle = .rounded
        deletePermanentlyButton.controlSize = .small
        deletePermanentlyButton.font = .systemFont(ofSize: 11)
        deletePermanentlyButton.target = self
        deletePermanentlyButton.action = #selector(deleteSelectedPermanently)
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
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
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

            restoreButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 12),
            restoreButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            deletePermanentlyButton.leadingAnchor.constraint(equalTo: restoreButton.trailingAnchor, constant: 8),
            deletePermanentlyButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func goBack() {
        onClose?()
    }

    @objc private func restoreSelected() {
        guard let record = selectedRecord() else { return }
        restore(record)
    }

    @objc private func deleteSelectedPermanently() {
        guard let row = focusedRecordRow() else { return }
        confirmPermanentDelete(atRow: row)
    }

    private func restore(_ record: Record) {
        store.restoreFromTrash(id: record.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.removeRecordFromList(id: record.id)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func confirmPermanentDelete(atRow row: Int) {
        guard let record = ListRowIndex.record(atTableRow: row, in: rows) else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete Permanently?"
        alert.informativeText = "“\(record.content)” will be deleted forever. This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        takeFocus()
        guard response == .alertFirstButtonReturn else { return }

        store.permanentlyDelete(id: record.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.removeRecordFromList(id: record.id)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let record = ListRowIndex.record(atTableRow: row, in: rows) else { return nil }
        let menu = NSMenu()
        let restoreItem = NSMenuItem(title: "Restore", action: #selector(restoreFromMenu(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.representedObject = record.id
        let deleteItem = NSMenuItem(title: "Delete Permanently", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = record.id
        menu.addItem(restoreItem)
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func restoreFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let record = records.first(where: { $0.id == id }) else { return }
        restore(record)
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let row = ListRowIndex.tableRow(forRecordID: id, in: rows) else { return }
        confirmPermanentDelete(atRow: row)
    }

    // MARK: - List

    private func rebuildRowsAndReload() {
        rows = TrashRows.build(records: records, projects: projects)
        tableView.reloadData()
    }

    private func removeRecordFromList(id: String) {
        let previousVisibleIDs = ListRowIndex.visibleRecords(in: rows).map(\.id)
        records.removeAll { $0.id == id }
        rebuildRowsAndReload()
        updateActionButtons()
        inheritFocus(removedID: id, previousVisibleIDs: previousVisibleIDs)
    }

    private func inheritFocus(removedID: String, previousVisibleIDs: [String]) {
        guard let index = previousVisibleIDs.firstIndex(of: removedID) else {
            takeFocus()
            return
        }
        let remaining = ListRowIndex.visibleRecords(in: rows)
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

    private func selectedRecord() -> Record? {
        ListRowIndex.record(atTableRow: tableView.selectedRow, in: rows)
    }

    private func focusedRecordRow() -> Int? {
        let row = tableView.selectedRow
        guard ListRowIndex.record(atTableRow: row, in: rows) != nil else { return nil }
        return row
    }

    private func updateActionButtons() {
        let enabled = selectedRecord() != nil
        restoreButton.isEnabled = enabled
        deletePermanentlyButton.isEnabled = enabled
    }

    private func presentPersistenceFailure(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

extension TrashViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .groupHeader(_, let title, _):
            let cell = tableView.makeView(withIdentifier: Self.headerCellIdentifier, owner: self) as? GroupHeaderCellView
                ?? GroupHeaderCellView(identifier: Self.headerCellIdentifier)
            cell.configure(title: title, isCollapsed: false)
            cell.onToggle = nil
            cell.onBuildMenu = nil
            return cell
        case .resolvedSectionHeader:
            return nil
        case .record(let record):
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? RecordCellView
                ?? RecordCellView(identifier: Self.cellIdentifier)
            cell.configure(with: record, indented: true, style: .trash)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .groupHeader, .resolvedSectionHeader: return Self.headerRowHeight
        case .record: return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        ListRowIndex.record(atTableRow: row, in: rows) != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }
}
