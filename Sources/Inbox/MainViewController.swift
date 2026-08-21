import AppKit

/// The main surface (Universal Input, Scope Bar, Record List, Utility bar)
/// plus the Trash secondary surface shown in its place (PRD §5.1, §12).
final class MainViewController: NSViewController {
    private let store: RecordStore
    private let trashViewController: TrashViewController
    /// Window-level undo stack for Move to Trash only (PRD §8.8). Field
    /// editors keep their own undo managers, so typing Undo does not mix
    /// with this stack.
    private let deleteUndoManager = UndoManager()

    private let mainSurface = NSView()
    private let inputField = NSTextField()
    private let scopeBar = ScopeBarView()
    private let tableView = RecordTableView()
    private let scrollView = NSScrollView()
    private let utilityBar = NSView()
    private let showResolvedCheckbox = NSButton(checkboxWithTitle: "Show Resolved", target: nil, action: nil)
    private let sortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let trashButton = NSButton(title: "Trash", target: nil, action: nil)

    private var records: [Record] = []
    /// Table rows derived from `records` + `projects` + collapse state.
    /// Every row↔record conversion goes through `ListRowIndex` on this array.
    private var rows: [ListRow] = []
    private var searchGeneration = 0

    /// Source of truth for search range and Create target (PRD §6.6).
    /// Read by AppDelegate to draw the Go menu's checkmark.
    private(set) var currentScope: Scope = .all
    private var projects: [Project] = []

    /// Notified whenever the Project list changes (initial load, or after a
    /// Create Project), so AppDelegate can rebuild the `⌘2…⌘0` menu section.
    var onProjectsChanged: (([Project]) -> Void)?

    private static let lastScopeProjectIDDefaultsKey = "com.inbox.lastScopeProjectID"
    private static let collapsedGroupsDefaultsKey = "com.inbox.collapsedGroups"
    private static let sortOrderDefaultsKey = "com.inbox.sortOrder"
    private static let showResolvedDefaultsKey = "com.inbox.showResolved"

    /// Global list sort (PRD §10). Restored in `viewDidLoad`.
    private var sortOrder: RecordSort = .newestFirst
    /// Show Resolved visibility (PRD §11). Default Off.
    private var showResolved = false

    /// Non-nil while a row's Content is in Inline Edit (PRD §8.5). This is
    /// the third focus state beyond Input Focus / Row Focus. It is a table
    /// row index, never a `records` array index — convert via `record(atTableRow:)`.
    private var editingRowIndex: Int?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("RecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")
    private static let resolvedHeaderCellIdentifier = NSUserInterfaceItemIdentifier("ResolvedSectionHeader")
    private static let rowHeight: CGFloat = 28
    private static let headerRowHeight: CGFloat = 24
    private static let resolvedHeaderRowHeight: CGFloat = 22

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
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
    }

    @objc private func remoteChangesApplied() {
        reloadProjectsThenSearch()
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
        inputField.placeholderString = "Capture or search…"
        inputField.font = .systemFont(ofSize: 16)
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.drawsBackground = false
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
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
    }

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
        tableView.onRequestReturnFocusToInput = { [weak self] in
            self?.focusInputAtEnd()
        }
        tableView.onAdjustPriority = { [weak self] row, adjustment in
            self?.adjustPriority(atRow: row, adjustment: adjustment)
        }
        tableView.onToggleResolve = { [weak self] row in
            self?.toggleResolve(atRow: row)
        }
        tableView.onRequestBeginInlineEdit = { [weak self] row in
            self?.beginInlineEdit(atRow: row)
        }
        tableView.onRequestMoveMenu = { [weak self] row in
            self?.popMoveMenu(atRow: row)
        }
        tableView.isNavigableRow = { [weak self] row in
            self?.record(atTableRow: row) != nil
        }
        tableView.onBuildContextMenu = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.onRequestDelete = { [weak self] row in
            self?.moveFocusedRecordToTrash(atRow: row)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func restoreDisplayPreferences() {
        sortOrder = RecordSort(rawValue: Preferences.store.string(forKey: Self.sortOrderDefaultsKey) ?? "") ?? .newestFirst
        showResolved = Preferences.store.bool(forKey: Self.showResolvedDefaultsKey)
    }

    private func setUpUtilityBar() {
        showResolvedCheckbox.font = .systemFont(ofSize: 11)
        showResolvedCheckbox.controlSize = .small
        showResolvedCheckbox.state = showResolved ? .on : .off
        showResolvedCheckbox.target = self
        showResolvedCheckbox.action = #selector(showResolvedToggled)
        showResolvedCheckbox.translatesAutoresizingMaskIntoConstraints = false

        sortPopUp.controlSize = .small
        sortPopUp.font = .systemFont(ofSize: 11)
        sortPopUp.removeAllItems()
        for order in RecordSort.allCases {
            sortPopUp.addItem(withTitle: order.menuTitle)
        }
        if let index = RecordSort.allCases.firstIndex(of: sortOrder) {
            sortPopUp.selectItem(at: index)
        }
        sortPopUp.target = self
        sortPopUp.action = #selector(sortOrderChanged)
        sortPopUp.translatesAutoresizingMaskIntoConstraints = false
        sortPopUp.setContentHuggingPriority(.required, for: .horizontal)

        trashButton.bezelStyle = .recessed
        trashButton.controlSize = .small
        trashButton.font = .systemFont(ofSize: 11)
        trashButton.target = self
        trashButton.action = #selector(openTrash)
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.setContentHuggingPriority(.required, for: .horizontal)

        utilityBar.translatesAutoresizingMaskIntoConstraints = false
        utilityBar.addSubview(showResolvedCheckbox)
        utilityBar.addSubview(sortPopUp)
        utilityBar.addSubview(trashButton)

        NSLayoutConstraint.activate([
            showResolvedCheckbox.leadingAnchor.constraint(equalTo: utilityBar.leadingAnchor, constant: 12),
            showResolvedCheckbox.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            sortPopUp.centerXAnchor.constraint(equalTo: utilityBar.centerXAnchor),
            sortPopUp.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            trashButton.trailingAnchor.constraint(equalTo: utilityBar.trailingAnchor, constant: -12),
            trashButton.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor)
        ])
    }

    @objc private func showResolvedToggled(_ sender: NSButton) {
        showResolved = sender.state == .on
        Preferences.store.set(showResolved, forKey: Self.showResolvedDefaultsKey)
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    @objc private func sortOrderChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard RecordSort.allCases.indices.contains(index) else { return }
        let selected = RecordSort.allCases[index]
        guard selected != sortOrder else { return }
        sortOrder = selected
        Preferences.store.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    private func setUpLayout() {
        mainSurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainSurface)

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        mainSurface.addSubview(inputField)
        mainSurface.addSubview(scopeBar)
        mainSurface.addSubview(topSeparator)
        mainSurface.addSubview(scrollView)
        mainSurface.addSubview(bottomSeparator)
        mainSurface.addSubview(utilityBar)

        NSLayoutConstraint.activate([
            mainSurface.topAnchor.constraint(equalTo: view.topAnchor),
            mainSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            inputField.topAnchor.constraint(equalTo: mainSurface.topAnchor, constant: 14),
            inputField.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor, constant: 14),
            inputField.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor, constant: -14),

            scopeBar.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 12),
            scopeBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scopeBar.heightAnchor.constraint(equalToConstant: 30),

            topSeparator.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
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
            utilityBar.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setUpTrashSurface() {
        addChild(trashViewController)
        let trashView = trashViewController.view
        trashView.translatesAutoresizingMaskIntoConstraints = false
        trashView.isHidden = true
        view.addSubview(trashView)
        trashViewController.onClose = { [weak self] in
            self?.closeTrash()
        }
        NSLayoutConstraint.activate([
            trashView.topAnchor.constraint(equalTo: view.topAnchor),
            trashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trashView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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

    // MARK: - Create

    private func handleCreate() {
        let content = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        // Clear immediately for next-frame feedback (PRD §17.2); the write
        // itself is confirmed asynchronously below.
        inputField.stringValue = ""

        store.createRecord(content: content, projectID: currentScope.createTargetProjectID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // The list is re-fetched after the write commits (same serial
                // queue), so this always observes the just-created Record
                // under the current sort.
                self.performSearch(term: "")
            case .failure(let error):
                self.presentCreateFailure(originalContent: content, error: error)
            }
        }
    }

    private func presentCreateFailure(originalContent: String, error: Error) {
        // No Silent Data Loss: put the content back so it isn't lost even
        // though writing it failed.
        inputField.stringValue = originalContent
        presentPersistenceFailure(error: error)
        focusInputAtEnd()
    }

    /// Generic failure alert for Row Focus actions (Priority, Resolve, Inline
    /// Edit) that, unlike Create, don't need to restore Input content or
    /// force any particular focus target — callers decide focus afterward.
    private func presentPersistenceFailure(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    // MARK: - Row Focus: Priority (PRD §8.4)

    private func adjustPriority(atRow row: Int, adjustment: PriorityAdjustment) {
        guard let record = record(atTableRow: row) else { return }
        let newPriority = adjustment.apply(to: record.priorityValue)
        guard newPriority != record.priorityValue else { return } // already at the boundary

        store.updatePriority(id: record.id, priority: newPriority.rawValue) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Rebuild so Priority sort can move the row; then re-select
                // by id (PRD §8.4 / §23.3) — Focus follows this Record.
                self.applyLocalRecordUpdate(id: record.id) { $0.priority = newPriority.rawValue }
                self.records = self.sortOrder.sorted(self.records)
                self.rebuildRowsAndReload()
                if let newRow = self.tableRow(forRecordID: record.id) {
                    self.returnFocusToRow(newRow)
                }
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    // MARK: - Row Focus: Resolve (PRD §8.6)

    private func toggleResolve(atRow row: Int) {
        guard let record = record(atTableRow: row) else { return }
        let willResolve = record.status == RecordStatus.open.rawValue
        let newStatus: RecordStatus = willResolve ? .resolved : .open

        store.setStatus(id: record.id, status: newStatus) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.applyResolveResult(recordID: record.id, resolved: willResolve)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    /// Space toggles Resolved (PRD §8.6). Show Resolved Off: the row leaves
    /// the list and Focus walks the remaining Open sequence. Show Resolved
    /// On: the row moves into the Resolved group but Focus stays on the next
    /// Open Record. Reopen moves the row back to Open and Focus follows it.
    private func applyResolveResult(recordID: String, resolved: Bool) {
        let previousOpenIDs = visibleRecords()
            .filter { $0.status == RecordStatus.open.rawValue }
            .map(\.id)

        applyLocalRecordUpdate(id: recordID) { rec in
            rec.status = (resolved ? RecordStatus.resolved : RecordStatus.open).rawValue
            rec.resolvedAt = resolved ? rec.updatedAt : nil
        }
        if resolved && !showResolved {
            records.removeAll { $0.id == recordID }
        }
        rebuildRowsAndReload()

        if resolved {
            let remainingOpenIDs = visibleRecords()
                .filter { $0.status == RecordStatus.open.rawValue }
                .map(\.id)
            if let nextID = RowFocusInheritance.nextOpenRecordID(
                afterResolving: recordID,
                previousOpenIDs: previousOpenIDs,
                remainingOpenIDs: remainingOpenIDs
            ), let row = tableRow(forRecordID: nextID) {
                returnFocusToRow(row)
            } else {
                focusInputAtEnd()
            }
        } else if let row = tableRow(forRecordID: recordID) {
            returnFocusToRow(row)
        } else {
            focusInputAtEnd()
        }
    }

    /// Focus inheritance (PRD §8.6) walks the visible Record sequence, not
    /// table rows — group headers and Resolved section headers are skipped
    /// the same way ↑↓ skip them.
    private func inheritFocus(removedID: String, previousVisibleIDs: [String]) {
        guard let index = previousVisibleIDs.firstIndex(of: removedID) else {
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

    // MARK: - Row Focus: Inline Edit (PRD §8.5)

    private func beginInlineEdit(atRow row: Int) {
        guard editingRowIndex == nil, let focused = record(atTableRow: row), view.window != nil else { return }

        // Nothing else in this Slice can trigger a search while a row is
        // being edited (Universal Input isn't first responder during Row
        // Focus / Inline Edit), but a search issued just before Enter was
        // pressed could still be in flight. Bumping the generation here
        // invalidates it the same way a newer keystroke would, so a late
        // `performSearch` completion can't call `reloadData()` and tear
        // apart the cell view out from under the active field editor. This
        // is the cheapest correct option — reusing an existing mechanism
        // rather than adding a separate "reload suspended" flag.
        searchGeneration += 1

        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? RecordCellView else { return }

        editingRowIndex = row
        cell.onEditingEnded = { [weak self] outcome in
            self?.handleInlineEditEnded(atRow: row, recordID: focused.id, originalContent: focused.content, outcome: outcome)
        }
        cell.beginEditing()
    }

    private func handleInlineEditEnded(
        atRow row: Int,
        recordID: String,
        originalContent: String,
        outcome: InlineEditOutcome
    ) {
        switch outcome {
        case .commit(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // No Silent Data Loss cuts both ways here: an empty commit must
            // not blank out the Record's Content, so it's treated the same
            // as Esc — restore the original text.
            guard !trimmed.isEmpty, trimmed != originalContent else {
                finishInlineEdit(atRow: row, returnFocus: true)
                return
            }
            store.updateContent(id: recordID, content: trimmed) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.applyLocalRecordUpdate(id: recordID) { $0.content = trimmed }
                case .failure(let error):
                    self.presentPersistenceFailure(error: error)
                }
                self.finishInlineEdit(atRow: row, returnFocus: true)
            }
        case .cancel:
            finishInlineEdit(atRow: row, returnFocus: true)
        case .interrupted:
            // Focus already moved elsewhere on its own — just restore the
            // cell's display state, don't fight it by reclaiming focus.
            finishInlineEdit(atRow: row, returnFocus: false)
        }
    }

    /// Ends Inline Edit for `row` and restores its cell to display mode,
    /// reading back from the Record at that table row — which by this point
    /// holds either the newly committed content or (Cancel / failed commit /
    /// empty commit) the untouched original.
    private func finishInlineEdit(atRow row: Int, returnFocus: Bool) {
        guard editingRowIndex == row else { return }
        editingRowIndex = nil
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecordCellView {
            if let record = record(atTableRow: row) {
                cell.configure(with: record, indented: isGrouped)
            }
            cell.endEditing()
            cell.onEditingEnded = nil
        }
        if returnFocus {
            returnFocusToRow(row)
        }
    }

    private func returnFocusToRow(_ row: Int) {
        guard let window = view.window, record(atTableRow: row) != nil else {
            focusInputAtEnd()
            return
        }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Scope (PRD §6.6, §7, §9)

    /// Loads the Project list, restores the last Scope from UserDefaults
    /// (falling back to All if it named a Project that no longer exists —
    /// PRD §7.1), then runs the first search. The single entry point for
    /// getting the Scope Bar and list into their starting state.
    private func loadProjectsAndRestoreScope() {
        store.projects.listProjects { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let projects):
                self.projects = projects
                self.currentScope = Self.restoredScope(projects: projects)
                self.scopeBar.update(scope: self.currentScope, projects: projects)
                self.onProjectsChanged?(projects)
                self.performSearch(term: self.inputField.stringValue)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
                self.performSearch(term: self.inputField.stringValue)
            }
        }
    }

    private static func restoredScope(projects: [Project]) -> Scope {
        guard let savedID = Preferences.store.string(forKey: lastScopeProjectIDDefaultsKey),
              projects.contains(where: { $0.id == savedID }) else {
            return .all
        }
        return .project(id: savedID)
    }

    private func persistCurrentScope() {
        switch currentScope {
        case .all:
            Preferences.store.removeObject(forKey: Self.lastScopeProjectIDDefaultsKey)
        case .project(let id):
            Preferences.store.set(id, forKey: Self.lastScopeProjectIDDefaultsKey)
        }
    }

    /// The single path every Scope change goes through — Scope Bar clicks,
    /// `⌘Number` menu items, and (S3b) All View Project rows all funnel here.
    /// Per PRD §6.6/§9: Input text and focus are left untouched (this method
    /// never touches first responder), the list re-runs under the new Scope,
    /// and Create Target updates for the next Enter.
    func switchScope(_ scope: Scope) {
        guard scope != currentScope else { return }
        currentScope = scope
        persistCurrentScope()
        scopeBar.update(scope: scope, projects: projects)
        performSearch(term: inputField.stringValue)
    }

    /// Scope Bar "+": a minimal NSAlert with an accessory text field (PRD
    /// §7.5 Create). An empty name creates nothing. Modal by nature — the
    /// "must not steal Input focus" rule is specific to Scope *selection*
    /// clicks, not this deliberate, self-contained creation flow — so focus
    /// is explicitly returned to Input afterward.
    private func promptCreateProject() {
        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "Project name"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        defer { focusInputAtEnd() }
        guard response == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        store.projects.createProject(name: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reloadProjectList()
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func reloadProjectList() {
        store.projects.listProjects { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let projects):
                let selectedID = self.record(atTableRow: self.tableView.selectedRow)?.id
                self.projects = projects
                self.scopeBar.update(scope: self.currentScope, projects: projects)
                self.onProjectsChanged?(projects)
                self.rebuildRowsAndReload()
                if let selectedID, let row = self.tableRow(forRecordID: selectedID) {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func reloadProjectsThenSearch() {
        store.projects.listProjects { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let projects):
                self.projects = projects
                if case .project(let id) = self.currentScope, !projects.contains(where: { $0.id == id }) {
                    self.currentScope = .all
                    self.persistCurrentScope()
                }
                self.scopeBar.update(scope: self.currentScope, projects: projects)
                self.onProjectsChanged?(projects)
                self.performSearch(term: self.inputField.stringValue)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func reorderProjects(_ orderedIDs: [String]) {
        store.projects.reorderProjects(orderedIDs: orderedIDs) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reloadProjectList()
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
                self.reloadProjectList()
            }
        }
    }

    // MARK: - Search

    private func performSearch(term: String, preservingFocus: Bool = false, selectRecordID: String? = nil) {
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
                if let selectRecordID, let row = self.tableRow(forRecordID: selectRecordID) {
                    self.returnFocusToRow(row)
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
                    self.inheritFocus(removedID: focusedID, previousVisibleIDs: previousVisibleIDs)
                }
            }
        }
    }

    // MARK: - Row ↔ Record mapping

    private var isGrouped: Bool { currentScope == .all }

    private func record(atTableRow row: Int) -> Record? {
        ListRowIndex.record(atTableRow: row, in: rows)
    }

    private func tableRow(forRecordID id: String) -> Int? {
        ListRowIndex.tableRow(forRecordID: id, in: rows)
    }

    private func visibleRecords() -> [Record] {
        ListRowIndex.visibleRecords(in: rows)
    }

    private func rebuildRows() {
        let trimmed = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = ListRows.build(
            records: records,
            projects: projects,
            grouped: isGrouped,
            hideEmptyGroups: !trimmed.isEmpty,
            isCollapsed: { isGroupCollapsed($0) },
            showResolved: showResolved
        )
    }

    private func rebuildRowsAndReload() {
        rebuildRows()
        tableView.reloadData()
    }

    private func applyLocalRecordUpdate(id: String, mutate: (inout Record) -> Void) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            mutate(&records[index])
        }
        if let row = tableRow(forRecordID: id), case .record(var rec) = rows[row] {
            mutate(&rec)
            rows[row] = .record(rec)
        }
    }

    // MARK: - Group collapse (PRD §7.2)

    private func collapseKey(_ id: GroupID) -> String {
        switch id {
        case .inbox: return "inbox"
        case .project(let projectID): return projectID
        }
    }

    private func isGroupCollapsed(_ id: GroupID) -> Bool {
        let stored = Set(Preferences.store.stringArray(forKey: Self.collapsedGroupsDefaultsKey) ?? [])
        return stored.contains(collapseKey(id))
    }

    private func setGroupCollapsed(_ id: GroupID, collapsed: Bool) {
        var stored = Set(Preferences.store.stringArray(forKey: Self.collapsedGroupsDefaultsKey) ?? [])
        if collapsed {
            stored.insert(collapseKey(id))
        } else {
            stored.remove(collapseKey(id))
        }
        Preferences.store.set(Array(stored), forKey: Self.collapsedGroupsDefaultsKey)
    }

    private func toggleGroup(_ id: GroupID) {
        let collapsing = !isGroupCollapsed(id)
        let previousVisibleIDs = visibleRecords().map(\.id)
        let focusedID = record(atTableRow: tableView.selectedRow)?.id
        setGroupCollapsed(id, collapsed: collapsing)
        rebuildRowsAndReload()

        if collapsing, let focusedID, tableRow(forRecordID: focusedID) == nil {
            if view.window?.firstResponder === tableView {
                inheritFocus(removedID: focusedID, previousVisibleIDs: previousVisibleIDs)
            } else {
                tableView.deselectAll(nil)
            }
        } else if let focusedID, let row = tableRow(forRecordID: focusedID) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - Project Rename / Delete (PRD §7.5)

    private func projectAdminMenu(projectID: String) -> NSMenu {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameProjectFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = projectID
        let deleteItem = NSMenuItem(title: "Delete…", action: #selector(deleteProjectFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = projectID
        menu.addItem(rename)
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func renameProjectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let project = projects.first(where: { $0.id == id }) else { return }
        promptRenameProject(project)
    }

    @objc private func deleteProjectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let project = projects.first(where: { $0.id == id }) else { return }
        confirmDeleteProject(project)
    }

    private func promptRenameProject(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.stringValue = project.name
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        defer { focusInputAtEnd() }
        guard response == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }

        store.projects.renameProject(id: project.id, name: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reloadProjectList()
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func confirmDeleteProject(_ project: Project) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Project “\(project.name)”?"
        alert.informativeText = "Records will not be deleted. They will move back to Inbox."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        defer { focusInputAtEnd() }
        guard response == .alertFirstButtonReturn else { return }

        store.projects.deleteProject(id: project.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if case .project(let currentID) = self.currentScope, currentID == project.id {
                    self.currentScope = .all
                    self.persistCurrentScope()
                }
                self.reloadProjectsThenSearch()
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    // MARK: - Move Record (PRD §8.7)

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .groupHeader(let id, _, _):
            guard case .project(let projectID) = id else { return nil }
            return projectAdminMenu(projectID: projectID)
        case .resolvedSectionHeader:
            return nil
        case .record(let record):
            let menu = NSMenu()
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveItem.submenu = makeMoveDestinationMenu(for: record)
            menu.addItem(moveItem)
            menu.addItem(.separator())
            let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(moveToTrashFromMenu(_:)), keyEquivalent: "")
            trashItem.target = self
            trashItem.representedObject = record.id
            menu.addItem(trashItem)
            return menu
        }
    }

    private func popMoveMenu(atRow row: Int) {
        guard let record = record(atTableRow: row) else { return }
        let menu = makeMoveDestinationMenu(for: record)
        let rect = tableView.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 40, y: rect.midY), in: tableView)
    }

    private func makeMoveDestinationMenu(for record: Record) -> NSMenu {
        let menu = NSMenu()
        let inbox = NSMenuItem(title: "Inbox", action: #selector(moveRecordFromMenu(_:)), keyEquivalent: "")
        inbox.target = self
        inbox.representedObject = RecordMoveCommand(recordID: record.id, projectID: nil)
        inbox.state = record.projectID == nil ? .on : .off
        menu.addItem(inbox)
        if !projects.isEmpty {
            menu.addItem(.separator())
        }
        for project in projects {
            let item = NSMenuItem(title: project.name, action: #selector(moveRecordFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RecordMoveCommand(recordID: record.id, projectID: project.id)
            item.state = record.projectID == project.id ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func moveRecordFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? RecordMoveCommand else { return }
        moveRecord(id: command.recordID, to: command.projectID)
    }

    private func moveRecord(id: String, to projectID: String?) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard record.projectID != projectID else { return }

        store.updateProject(id: id, projectID: projectID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.applyMoveResult(recordID: id, newProjectID: projectID)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func applyMoveResult(recordID: String, newProjectID: String?) {
        let leavesCurrentScope: Bool
        switch currentScope {
        case .all:
            leavesCurrentScope = false
        case .project(let id):
            leavesCurrentScope = newProjectID != id
        }

        if leavesCurrentScope {
            let previousVisibleIDs = visibleRecords().map(\.id)
            records.removeAll { $0.id == recordID }
            rebuildRowsAndReload()
            inheritFocus(removedID: recordID, previousVisibleIDs: previousVisibleIDs)
            return
        }

        applyLocalRecordUpdate(id: recordID) { $0.projectID = newProjectID }
        let destination: GroupID = newProjectID.map { .project($0) } ?? .inbox
        setGroupCollapsed(destination, collapsed: false)
        rebuildRowsAndReload()
        if let row = tableRow(forRecordID: recordID) {
            returnFocusToRow(row)
        }
    }

    // MARK: - Move to Trash (PRD §8.8) and Undo

    private var isShowingTrash: Bool { !trashViewController.view.isHidden }

    private func moveFocusedRecordToTrash(atRow row: Int) {
        guard editingRowIndex == nil, let record = record(atTableRow: row) else { return }
        moveRecordToTrash(id: record.id)
    }

    @objc private func moveToTrashFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        moveRecordToTrash(id: id)
    }

    private func moveRecordToTrash(id: String) {
        store.moveToTrash(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.registerUndoRestore(id: id)
                self.applyMoveToTrashUI(recordID: id)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    /// Inverse of `moveRecordToTrash`, invoked by UndoManager. Registers the
    /// redo action synchronously while `isUndoing` is still true — the store
    /// write itself is async and must not be the place that re-registers.
    private func restoreRecordFromTrashForUndo(id: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.moveRecordToTrashForRedo(id: id)
        }
        undoManager?.setActionName("Move to Trash")
        store.restoreFromTrash(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record):
                self.applyRestoreUI(record)
            case .failure:
                self.refreshVisibleSurface()
            }
        }
    }

    private func moveRecordToTrashForRedo(id: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRecordFromTrashForUndo(id: id)
        }
        undoManager?.setActionName("Move to Trash")
        store.moveToTrash(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.applyMoveToTrashUI(recordID: id)
            case .failure(let error):
                self.presentPersistenceFailure(error: error)
            }
        }
    }

    private func registerUndoRestore(id: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRecordFromTrashForUndo(id: id)
        }
        undoManager?.setActionName("Move to Trash")
    }

    private func applyMoveToTrashUI(recordID: String) {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
            return
        }
        let previousVisibleIDs = visibleRecords().map(\.id)
        records.removeAll { $0.id == recordID }
        rebuildRowsAndReload()
        inheritFocus(removedID: recordID, previousVisibleIDs: previousVisibleIDs)
    }

    private func applyRestoreUI(_ record: Record) {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
            return
        }
        performSearch(term: inputField.stringValue, preservingFocus: true, selectRecordID: record.id)
    }

    private func refreshVisibleSurface() {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
        } else {
            performSearch(term: inputField.stringValue, preservingFocus: true)
        }
    }

    // MARK: - Trash surface (PRD §12)

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

    // MARK: - UI smoke inspection

    /// Narrow read-only hooks for `UISmokeRunner`. Not a public API.
    var smokeInputString: String { inputField.stringValue }
    var smokeVisibleRecords: [Record] { visibleRecords() }
    var smokeSelectedRecord: Record? { record(atTableRow: tableView.selectedRow) }

    func smokeIsInputFirstResponder() -> Bool {
        guard let window = view.window else { return false }
        let responder = window.firstResponder
        return responder === inputField || responder === inputField.currentEditor()
    }

    func smokeIsTableFirstResponder() -> Bool {
        view.window?.firstResponder === tableView
    }
}

private final class RecordMoveCommand: NSObject {
    let recordID: String
    let projectID: String?

    init(recordID: String, projectID: String?) {
        self.recordID = recordID
        self.projectID = projectID
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
        case .resolvedSectionHeader:
            let cell = tableView.makeView(withIdentifier: Self.resolvedHeaderCellIdentifier, owner: self) as? ResolvedSectionHeaderCellView
                ?? ResolvedSectionHeaderCellView(identifier: Self.resolvedHeaderCellIdentifier)
            cell.configure(indented: isGrouped)
            return cell
        case .record(let record):
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? RecordCellView
                ?? RecordCellView(identifier: Self.cellIdentifier)
            cell.configure(with: record, indented: isGrouped)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .groupHeader: return Self.headerRowHeight
        case .resolvedSectionHeader: return Self.resolvedHeaderRowHeight
        case .record: return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        record(atTableRow: row) != nil
    }
}
