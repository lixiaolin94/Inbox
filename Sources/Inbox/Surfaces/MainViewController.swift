import AppKit

/// The main surface (Universal Input, Scope Bar, Record List, Utility bar)
/// plus the Trash secondary surface shown in its place (PRD §5.1, §12).
///
/// Split by concern across files; members below are module-internal so the
/// extensions can reach them — they are not API for anything else:
/// - this file: state, set-up/layout, focus routing, search, row mapping,
///   table data source;
/// - `+Records`: every Record action (Create, Priority, Resolve, Copy,
///   Inline Edit, Move, Trash + Undo);
/// - `+Projects`: Project list, Scope, Project admin, drag-to-move;
/// - `+Smoke`: read-only hooks for `--ui-smoke`.
final class MainViewController: NSViewController {
    let store: RecordStore
    let trashViewController: TrashViewController
    /// Window-level undo stack for Move to Trash only (PRD §8.8). Field
    /// editors keep their own undo managers, so typing Undo does not mix
    /// with this stack.
    private let deleteUndoManager = UndoManager()

    let mainSurface = NSView()
    let universalInput = UniversalInputView()
    var inputField: NSTextField { universalInput.textField }
    let scopeBar = ScopeBarView()
    let tableView = RecordTableView()
    let scrollView = NSScrollView()
    private let utilityBar = NSView()
    private let resolvedChip = ScopeChipButton(title: "Resolved")
    private let sortChip = ScopeChipButton(title: "Newest")
    let offlineNoticeLabel = NSTextField(labelWithString: "iCloud unavailable · offline")
    private let trashButton = ScopeChipButton(title: "Trash")

    var records: [Record] = []
    /// Table rows derived from `records` + `projects` + collapse state.
    /// Every row↔record conversion goes through `ListRowIndex` on this array.
    var rows: [ListRow] = []
    /// Bumped by every search and by Inline Edit, so a stale completion can
    /// never reload the table out from under the user.
    var searchGeneration = 0

    /// Source of truth for search range and Create target (PRD §6.6).
    /// Read by AppDelegate to draw the Go menu's checkmark.
    var currentScope: Scope = .all
    var projects: [Project] = []

    /// Notified whenever the Project list changes (initial load, or after a
    /// Create Project), so AppDelegate can rebuild the `⌘2…⌘0` menu section.
    var onProjectsChanged: (([Project]) -> Void)?

    /// Global list sort (PRD §10) and Show Resolved (PRD §11), mirrored
    /// from Preferences in `viewDidLoad` and written back on change.
    var sortOrder: RecordSort = .newestFirst
    var showResolved = false

    /// Non-nil while a row's Content is in Inline Edit (PRD §8.5). This is
    /// the third focus state beyond Input Focus / Row Focus. It is a table
    /// row index, never a `records` array index — convert via `record(atTableRow:)`.
    var editingRowIndex: Int?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("RecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")

    init(store: RecordStore) {
        self.store = store
        self.trashViewController = TrashViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    override var undoManager: UndoManager? {
        deleteUndoManager
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: MainWindowGeometry.defaultContentSize))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Glass input draws a drop shadow outside its bounds (visible on
        // macOS 26). Clipping here shears that shadow into a hard edge.
        effect.clipsToBounds = false
        view = effect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        restoreDisplayPreferences()
        setUpInput()
        setUpScopeBar()
        setUpTable()
        setUpUtilityBar()
        setUpLayout()
        setUpTrashSurface()
        loadProjectsAndRestoreScope()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteChangesApplied),
            name: .inboxDidApplyRemoteChanges,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: .inboxAppearanceDidChange,
            object: nil
        )
    }

    @objc private func remoteChangesApplied() {
        reloadProjectsAndSearch()
        if isShowingTrash {
            trashViewController.reload(projects: projects)
        }
    }

    @objc private func appearanceDidChange() {
        tableView.rowHeight = Preferences.recordRowMinHeight
        rebuildRowsAndReload()
        if isShowingTrash {
            trashViewController.reload(projects: projects)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInputAtEnd()
    }

    // MARK: - Set up

    private func setUpInput() {
        inputField.delegate = self
        universalInput.translatesAutoresizingMaskIntoConstraints = false
        // Default NSTextField hugging is 750; with leading+trailing pins that
        // would rather keep the window at the field's intrinsic width than
        // let the user widen it. The scroll view is the expanding spacer.
        universalInput.setContentHuggingPriority(.defaultLow, for: .horizontal)
        universalInput.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setUpScopeBar() {
        scopeBar.translatesAutoresizingMaskIntoConstraints = false
        scopeBar.onSelectScope = { [weak self] scope in
            self?.switchScope(scope)
        }
        scopeBar.onCreateProject = { [weak self] in
            self?.promptCreateProject()
        }
        scopeBar.onReorderProjects = { [weak self] orderedIDs in
            self?.reorderProjects(orderedIDs)
        }
        scopeBar.onBuildProjectMenu = { [weak self] projectID in
            self?.projectAdminMenu(projectID: projectID)
        }
        scopeBar.onDropRecords = { [weak self] ids, projectID in
            self?.moveRecords(ids: ids, to: projectID)
        }
    }

    private func setUpTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        // `.plain` still insets cells ~10pt from the scroll edge, which
        // parked list text under All's letters (the chip's inner padding)
        // instead of All's capsule edge. Full width puts the 16pt rail on
        // the same window x as the chip.
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = Preferences.recordRowMinHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        // Drag source/target for All View drag-to-move (PRD §8.7 semantics,
        // drag UI). Local-only: rows never leave the app as a drag.
        tableView.registerForDraggedTypes([RecordDragTypes.recordID])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onRequestReturnFocusToInput = { [weak self] in
            self?.focusInputAtEnd()
        }
        tableView.onAdjustPriority = { [weak self] rows, adjustment in
            self?.adjustPriority(atRows: rows, adjustment: adjustment)
        }
        tableView.onToggleResolve = { [weak self] rows in
            self?.toggleResolve(atRows: rows)
        }
        tableView.onRequestBeginInlineEdit = { [weak self] row in
            self?.beginInlineEdit(atRow: row)
        }
        tableView.onRequestMoveMenu = { [weak self] rows in
            self?.popMoveMenu(forRows: rows)
        }
        tableView.isNavigableRow = { [weak self] row in
            self?.record(atTableRow: row) != nil
        }
        tableView.onBuildContextMenu = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.onRequestDelete = { [weak self] rows in
            self?.moveSelectedRecordsToTrash(atRows: rows)
        }
        tableView.onRequestCopy = { [weak self] rows in
            self?.copyRecords(atRows: rows)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        tableView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func restoreDisplayPreferences() {
        sortOrder = Preferences.sortOrder
        showResolved = Preferences.showResolved
    }

    private func setUpUtilityBar() {
        applyResolvedChipSymbol()
        resolvedChip.onClick = { [weak self] in self?.toggleShowResolved() }
        resolvedChip.translatesAutoresizingMaskIntoConstraints = false
        resolvedChip.setContentHuggingPriority(.required, for: .horizontal)

        sortChip.chipTitle = sortOrder.chipTitle
        sortChip.onClick = { [weak self] in self?.presentSortMenu() }
        sortChip.translatesAutoresizingMaskIntoConstraints = false
        sortChip.setContentHuggingPriority(.required, for: .horizontal)

        trashButton.onClick = { [weak self] in self?.openTrash() }
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.setContentHuggingPriority(.required, for: .horizontal)

        offlineNoticeLabel.font = .systemFont(ofSize: 11)
        offlineNoticeLabel.textColor = .secondaryLabelColor
        offlineNoticeLabel.isHidden = true
        offlineNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineNoticeLabel.setContentHuggingPriority(.required, for: .horizontal)
        offlineNoticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        utilityBar.translatesAutoresizingMaskIntoConstraints = false
        utilityBar.addSubview(resolvedChip)
        utilityBar.addSubview(sortChip)
        utilityBar.addSubview(offlineNoticeLabel)
        utilityBar.addSubview(trashButton)

        NSLayoutConstraint.activate([
            resolvedChip.leadingAnchor.constraint(equalTo: utilityBar.leadingAnchor, constant: LayoutChrome.contentInset),
            resolvedChip.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            trashButton.trailingAnchor.constraint(equalTo: utilityBar.trailingAnchor, constant: -LayoutChrome.contentInset),
            trashButton.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            sortChip.leadingAnchor.constraint(equalTo: resolvedChip.trailingAnchor, constant: LayoutChrome.chipSpacing),
            sortChip.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            offlineNoticeLabel.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            offlineNoticeLabel.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),
            offlineNoticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sortChip.trailingAnchor, constant: 8)
        ])
    }

    func showOfflineNotice(_ visible: Bool) {
        offlineNoticeLabel.isHidden = !visible
    }

    private func applyResolvedChipSymbol() {
        resolvedChip.symbolName = showResolved ? "eye" : "eye.slash"
        resolvedChip.toolTip = showResolved ? "Hide Resolved" : "Show Resolved"
    }

    private func toggleShowResolved() {
        showResolved.toggle()
        applyResolvedChipSymbol()
        Preferences.showResolved = showResolved
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    private func presentSortMenu() {
        let menu = NSMenu()
        for order in RecordSort.allCases {
            let item = NSMenuItem(title: order.menuTitle, action: #selector(sortMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = order == sortOrder ? .on : .off
            menu.addItem(item)
        }
        let point = NSPoint(x: 0, y: sortChip.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sortChip)
    }

    @objc private func sortMenuChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = RecordSort(rawValue: raw),
              selected != sortOrder else { return }
        sortOrder = selected
        sortChip.chipTitle = selected.chipTitle
        Preferences.sortOrder = sortOrder
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    private func setUpLayout() {
        // Fill the window via autoresizing, not Auto Layout pins to the
        // content view. Edge constraints on the content view turn the
        // NSWindow into an Auto Layout window, which then sizes itself to
        // fittingSize (~28pt = input leading+trailing padding). Internal
        // layout below still uses Auto Layout inside `mainSurface`.
        mainSurface.translatesAutoresizingMaskIntoConstraints = true
        mainSurface.autoresizingMask = [.width, .height]
        mainSurface.frame = view.bounds
        mainSurface.clipsToBounds = false
        view.addSubview(mainSurface)

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Input last so its glass shadow paints over the Scope Bar instead
        // of being covered by the bar's clip view.
        mainSurface.addSubview(scopeBar)
        mainSurface.addSubview(topSeparator)
        mainSurface.addSubview(scrollView)
        mainSurface.addSubview(bottomSeparator)
        mainSurface.addSubview(utilityBar)
        mainSurface.addSubview(universalInput)

        NSLayoutConstraint.activate([
            universalInput.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            universalInput.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor, constant: 16),
            universalInput.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor, constant: -16),
            universalInput.heightAnchor.constraint(equalToConstant: UniversalInputView.chromeHeight),

            scopeBar.topAnchor.constraint(equalTo: universalInput.bottomAnchor, constant: LayoutChrome.neighborGap),
            scopeBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scopeBar.heightAnchor.constraint(equalToConstant: 36),

            topSeparator.topAnchor.constraint(equalTo: scopeBar.bottomAnchor, constant: LayoutChrome.neighborGap),
            topSeparator.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),

            utilityBar.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            utilityBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            utilityBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            utilityBar.bottomAnchor.constraint(equalTo: mainSurface.bottomAnchor),
            utilityBar.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func setUpTrashSurface() {
        addChild(trashViewController)
        let trashView = trashViewController.view
        trashView.translatesAutoresizingMaskIntoConstraints = true
        trashView.autoresizingMask = [.width, .height]
        trashView.frame = view.bounds
        trashView.isHidden = true
        view.addSubview(trashView)
        trashViewController.onClose = { [weak self] in
            self?.closeTrash()
        }
    }

    // MARK: - Focus routing

    /// Places the caret at the end of Universal Input. Used on launch,
    /// after closing Trash, and on every reopen/activation path (PRD §6.2)
    /// so the first keystroke is never dropped.
    func focusInputAtEnd() {
        guard let window = view.window else { return }
        window.makeFirstResponder(inputField)
        if let editor = inputField.currentEditor() {
            let end = editor.string.utf16.count
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func focusFirstRow() {
        guard let row = tableView.firstNavigableRow(), let window = view.window else { return }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Focus inheritance (PRD §8.6) walks the visible Record sequence, not
    /// table rows — group headers are skipped the same way ↑↓ skip them. For a batch removal the first removed id's
    /// index doubles as its slot in the remaining sequence (no removed rows
    /// precede it), so the single-removal rule covers both cases.
    func inheritFocus(removedIDs: [String], previousVisibleIDs: [String]) {
        let idSet = Set(removedIDs)
        guard let index = previousVisibleIDs.firstIndex(where: { idSet.contains($0) }) else {
            focusInputAtEnd()
            return
        }
        let remaining = visibleRecords()
        if let nextIndex = RowFocusInheritance.nextFocusIndex(afterRemovingRowAt: index, remainingCount: remaining.count),
           let row = tableRow(forRecordID: remaining[nextIndex].id) {
            returnFocusToRow(row)
        } else {
            focusInputAtEnd()
        }
    }

    func returnFocusToRow(_ row: Int) {
        guard let window = view.window, record(atTableRow: row) != nil else {
            focusInputAtEnd()
            return
        }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Multi-select counterpart of `returnFocusToRow`: re-selects every id
    /// still visible (a batch action may have moved rows), scrolled to the
    /// topmost. All gone → back to Universal Input.
    func returnFocusToRecords(ids: [String]) {
        guard let window = view.window else { return }
        var indexes = IndexSet()
        for id in ids {
            if let row = tableRow(forRecordID: id) {
                indexes.insert(row)
            }
        }
        guard let first = indexes.first else {
            focusInputAtEnd()
            return
        }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        tableView.scrollRowToVisible(first)
    }

    // MARK: - Search

    func performSearch(term: String, preservingFocus: Bool = false, selectRecordIDs: [String] = []) {
        searchGeneration += 1
        let generation = searchGeneration
        let focusedID = preservingFocus ? record(atTableRow: tableView.selectedRow)?.id : nil
        let previousVisibleIDs = preservingFocus ? visibleRecords().map(\.id) : []
        let wasTableFocused = preservingFocus && view.window?.firstResponder === tableView
        store.search(
            term: term,
            scope: currentScope,
            token: generation,
            sortOrder: sortOrder,
            includeResolved: showResolved
        ) { [weak self] result, token in
            guard let self, token == self.searchGeneration else { return }
            if case .success(let records) = result {
                self.records = records
                self.rebuildRowsAndReload()
                if !selectRecordIDs.isEmpty, selectRecordIDs.contains(where: { self.tableRow(forRecordID: $0) != nil }) {
                    self.returnFocusToRecords(ids: selectRecordIDs)
                    return
                }
                guard preservingFocus, let focusedID else { return }
                if let row = self.tableRow(forRecordID: focusedID) {
                    if wasTableFocused {
                        self.returnFocusToRow(row)
                    } else {
                        self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        self.tableView.scrollRowToVisible(row)
                    }
                } else if wasTableFocused {
                    self.inheritFocus(removedIDs: [focusedID], previousVisibleIDs: previousVisibleIDs)
                }
            }
        }
    }

    // MARK: - Row ↔ Record mapping

    var isGrouped: Bool { currentScope == .all }

    func record(atTableRow row: Int) -> Record? {
        ListRowIndex.record(atTableRow: row, in: rows)
    }

    func tableRow(forRecordID id: String) -> Int? {
        ListRowIndex.tableRow(forRecordID: id, in: rows)
    }

    func visibleRecords() -> [Record] {
        ListRowIndex.visibleRecords(in: rows)
    }

    private func rebuildRows() {
        let trimmed = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = Preferences.collapsedGroupKeys
        rows = ListRows.build(
            records: records,
            projects: projects,
            grouped: isGrouped,
            hideEmptyGroups: !trimmed.isEmpty,
            isCollapsed: { collapsed.contains(Preferences.collapseKey($0)) },
            showResolved: showResolved
        )
    }

    func rebuildRowsAndReload() {
        rebuildRows()
        tableView.reloadData()
    }

    func applyLocalRecordUpdate(id: String, mutate: (inout Record) -> Void) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            mutate(&records[index])
        }
        if let row = tableRow(forRecordID: id), case .record(var rec) = rows[row] {
            mutate(&rec)
            rows[row] = .record(rec)
        }
    }

    func records(atTableRows rowIndexes: IndexSet) -> [Record] {
        rowIndexes.compactMap { record(atTableRow: $0) }
    }

    // MARK: - Group collapse (PRD §7.2)

    private func toggleGroup(_ id: GroupID) {
        let collapsing = !Preferences.isGroupCollapsed(id)
        let previousVisibleIDs = visibleRecords().map(\.id)
        let focusedID = record(atTableRow: tableView.selectedRow)?.id
        Preferences.setGroupCollapsed(id, collapsing)
        rebuildRowsAndReload()

        if collapsing, let focusedID, tableRow(forRecordID: focusedID) == nil {
            if view.window?.firstResponder === tableView {
                inheritFocus(removedIDs: [focusedID], previousVisibleIDs: previousVisibleIDs)
            } else {
                tableView.deselectAll(nil)
            }
        } else if let focusedID, let row = tableRow(forRecordID: focusedID) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - Trash surface (PRD §12)

    var isShowingTrash: Bool { !trashViewController.view.isHidden }

    @objc private func openTrash() {
        mainSurface.isHidden = true
        trashViewController.view.isHidden = false
        trashViewController.takeFocus()
        trashViewController.reload(projects: projects)
    }

    private func closeTrash() {
        trashViewController.view.isHidden = true
        mainSurface.isHidden = false
        performSearch(term: inputField.stringValue)
        focusInputAtEnd()
    }

    func refreshVisibleSurface() {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
        } else {
            performSearch(term: inputField.stringValue, preservingFocus: true)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension MainViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        performSearch(term: inputField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            handleCreate()
            return true
        case #selector(NSResponder.moveDown(_:)):
            focusFirstRow()
            return true
        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension MainViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClearTableRowView.dequeue(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .groupHeader(let id, let title, let isCollapsed):
            let cell = tableView.makeView(withIdentifier: Self.headerCellIdentifier, owner: self) as? GroupHeaderCellView
                ?? GroupHeaderCellView(identifier: Self.headerCellIdentifier)
            cell.configure(title: title, isCollapsed: isCollapsed)
            cell.onToggle = { [weak self] in
                self?.toggleGroup(id)
            }
            cell.onBuildMenu = { [weak self] in
                guard case .project(let projectID) = id else { return nil }
                return self?.projectAdminMenu(projectID: projectID)
            }
            return cell
        case .record(let record):
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? RecordCellView
                ?? RecordCellView(identifier: Self.cellIdentifier)
            cell.configure(with: record)
            return cell
        }
    }

    /// Multi-select filter: only Record rows can enter the selection —
    /// covers clicks, ⇧clicks, ⌘clicks, and rubber-band drags in one place
    /// (with this implemented, `shouldSelectRow` would not be consulted).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { record(atTableRow: $0) != nil })
    }
}
