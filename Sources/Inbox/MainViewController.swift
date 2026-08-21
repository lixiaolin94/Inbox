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
    private let universalInput = UniversalInputView()
    private var inputField: NSTextField { universalInput.textField }
    private let scopeBar = ScopeBarView()
    private let tableView = RecordTableView()
    private let scrollView = NSScrollView()
    private let utilityBar = NSView()
    private let showResolvedCheckbox = NSButton(checkboxWithTitle: "Show Resolved", target: nil, action: nil)
    private let sortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let offlineNoticeLabel = NSTextField(labelWithString: "iCloud unavailable · offline")
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
        reloadProjectsThenSearch()
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
        tableView.style = .plain
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

        offlineNoticeLabel.font = .systemFont(ofSize: 11)
        offlineNoticeLabel.textColor = .secondaryLabelColor
        offlineNoticeLabel.isHidden = true
        offlineNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineNoticeLabel.setContentHuggingPriority(.required, for: .horizontal)
        offlineNoticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        utilityBar.translatesAutoresizingMaskIntoConstraints = false
        utilityBar.addSubview(showResolvedCheckbox)
        utilityBar.addSubview(sortPopUp)
        utilityBar.addSubview(offlineNoticeLabel)
        utilityBar.addSubview(trashButton)

        NSLayoutConstraint.activate([
            showResolvedCheckbox.leadingAnchor.constraint(equalTo: utilityBar.leadingAnchor, constant: 12),
            showResolvedCheckbox.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            sortPopUp.centerXAnchor.constraint(equalTo: utilityBar.centerXAnchor),
            sortPopUp.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            trashButton.trailingAnchor.constraint(equalTo: utilityBar.trailingAnchor, constant: -12),
            trashButton.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),

            offlineNoticeLabel.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            offlineNoticeLabel.centerYAnchor.constraint(equalTo: utilityBar.centerYAnchor),
            offlineNoticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sortPopUp.trailingAnchor, constant: 8)
        ])
    }

    func showOfflineNotice(_ visible: Bool) {
        offlineNoticeLabel.isHidden = !visible
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
        // Fill the window via autoresizing, not Auto Layout pins to the
        // content view. Edge constraints on the content view turn the
        // NSWindow into an Auto Layout window, which then sizes itself to
        // fittingSize (~28pt = input leading+trailing padding). Internal
        // layout below still uses Auto Layout inside `mainSurface`.
        mainSurface.translatesAutoresizingMaskIntoConstraints = true
        mainSurface.autoresizingMask = [.width, .height]
        mainSurface.frame = view.bounds
        view.addSubview(mainSurface)

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        mainSurface.addSubview(universalInput)
        mainSurface.addSubview(scopeBar)
        mainSurface.addSubview(topSeparator)
        mainSurface.addSubview(scrollView)
        mainSurface.addSubview(bottomSeparator)
        mainSurface.addSubview(utilityBar)

        NSLayoutConstraint.activate([
            universalInput.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            universalInput.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor, constant: 16),
            universalInput.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor, constant: -16),
            universalInput.heightAnchor.constraint(equalToConstant: UniversalInputView.capsuleHeight),

            scopeBar.topAnchor.constraint(equalTo: universalInput.bottomAnchor, constant: 8),
            scopeBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scopeBar.heightAnchor.constraint(equalToConstant: 36),

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

    // MARK: - Batch plumbing (multi-select)

    /// Fires one store write per id and reports once after the last
    /// completion (all store completions land on the main queue, in order,
    /// so the shared counters need no locking). On any failure the caller
    /// gets the first error; the store's serial queue has still applied the
    /// other writes, so callers must re-sync from the DB rather than patch
    /// local state.
    private func performBatch(
        ids: [String],
        operation: (String, @escaping (Result<Void, Error>) -> Void) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard !ids.isEmpty else {
            completion(nil)
            return
        }
        var remaining = ids.count
        var firstError: Error?
        for id in ids {
            operation(id) { result in
                if case .failure(let error) = result, firstError == nil {
                    firstError = error
                }
                remaining -= 1
                if remaining == 0 {
                    completion(firstError)
                }
            }
        }
    }

    private func records(atTableRows rowIndexes: IndexSet) -> [Record] {
        rowIndexes.compactMap { record(atTableRow: $0) }
    }

    // MARK: - Row Focus: Priority (PRD §8.4)

    private func adjustPriority(atRows rowIndexes: IndexSet, adjustment: PriorityAdjustment) {
        let selected = records(atTableRows: rowIndexes)
        // Each Record clamps at its own boundary; ones already at P0/P3
        // stay put while the rest move one step.
        let targets = selected.compactMap { record -> (id: String, priority: Priority)? in
            let newPriority = adjustment.apply(to: record.priorityValue)
            return newPriority == record.priorityValue ? nil : (record.id, newPriority)
        }
        guard !targets.isEmpty else { return }
        let selectedIDs = selected.map(\.id)

        performBatch(ids: targets.map(\.id), operation: { id, done in
            guard let priority = targets.first(where: { $0.id == id })?.priority else { return }
            store.updatePriority(id: id, priority: priority.rawValue, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.presentPersistenceFailure(error: error)
                self.refreshVisibleSurface()
                return
            }
            // Rebuild so Priority sort can move the rows; then re-select
            // by id (PRD §8.4 / §23.3) — Focus follows these Records.
            for target in targets {
                self.applyLocalRecordUpdate(id: target.id) { $0.priority = target.priority.rawValue }
            }
            self.records = self.sortOrder.sorted(self.records)
            self.rebuildRowsAndReload()
            self.returnFocusToRecords(ids: selectedIDs)
        }
    }

    // MARK: - Row Focus: Resolve (PRD §8.6)

    /// Space on a selection: if any selected Record is Open the whole action
    /// is Resolve (Open ones flip, Resolved ones stay); only an all-Resolved
    /// selection means Reopen. Matches the single-row toggle when one row is
    /// selected.
    private func toggleResolve(atRows rowIndexes: IndexSet) {
        let selected = records(atTableRows: rowIndexes)
        guard !selected.isEmpty else { return }
        let openIDs = selected.filter { $0.status == RecordStatus.open.rawValue }.map(\.id)
        let willResolve = !openIDs.isEmpty
        let targetIDs = willResolve ? openIDs : selected.map(\.id)
        let newStatus: RecordStatus = willResolve ? .resolved : .open

        performBatch(ids: targetIDs, operation: { id, done in
            store.setStatus(id: id, status: newStatus, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.presentPersistenceFailure(error: error)
                self.refreshVisibleSurface()
                return
            }
            self.applyResolveResult(recordIDs: targetIDs, resolved: willResolve)
        }
    }

    /// Space toggles Resolved (PRD §8.6). Show Resolved Off: the rows leave
    /// the list and Focus walks the remaining Open sequence. Show Resolved
    /// On: the rows move into the Resolved group but Focus stays on the next
    /// Open Record. Reopen moves the rows back to Open and Focus follows them.
    private func applyResolveResult(recordIDs: [String], resolved: Bool) {
        let idSet = Set(recordIDs)
        let previousOpenIDs = visibleRecords()
            .filter { $0.status == RecordStatus.open.rawValue }
            .map(\.id)

        for id in recordIDs {
            applyLocalRecordUpdate(id: id) { rec in
                rec.status = (resolved ? RecordStatus.resolved : RecordStatus.open).rawValue
                rec.resolvedAt = resolved ? rec.updatedAt : nil
            }
        }
        if resolved && !showResolved {
            records.removeAll { idSet.contains($0.id) }
        }
        rebuildRowsAndReload()

        if resolved {
            let remainingOpenIDs = visibleRecords()
                .filter { $0.status == RecordStatus.open.rawValue }
                .map(\.id)
            // The first resolved id's Open index equals its slot in the
            // remaining sequence (nothing before it was removed), so the
            // single-removal inheritance rule applies unchanged.
            if let firstIndex = previousOpenIDs.firstIndex(where: { idSet.contains($0) }),
               let nextIndex = RowFocusInheritance.nextFocusIndex(
                   afterRemovingRowAt: firstIndex,
                   remainingCount: remainingOpenIDs.count
               ),
               let row = tableRow(forRecordID: remainingOpenIDs[nextIndex]) {
                returnFocusToRow(row)
            } else {
                focusInputAtEnd()
            }
        } else {
            returnFocusToRecords(ids: recordIDs)
        }
    }

    /// Focus inheritance (PRD §8.6) walks the visible Record sequence, not
    /// table rows — group headers and Resolved section headers are skipped
    /// the same way ↑↓ skip them. For a batch removal the first removed id's
    /// index doubles as its slot in the remaining sequence (no removed rows
    /// precede it), so the single-removal rule covers both cases.
    private func inheritFocus(removedIDs: [String], previousVisibleIDs: [String]) {
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

    // MARK: - Copy (⌘C)

    /// Puts the selected Records' Content on the general pasteboard, one
    /// Record per line in display order.
    private func copyRecords(atRows rowIndexes: IndexSet) {
        let contents = records(atTableRows: rowIndexes).map(\.content)
        guard !contents.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents.joined(separator: "\n"), forType: .string)
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

    /// Multi-select counterpart of `returnFocusToRow`: re-selects every id
    /// still visible (a batch action may have moved rows), scrolled to the
    /// topmost. All gone → back to Universal Input.
    private func returnFocusToRecords(ids: [String]) {
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

    private func performSearch(term: String, preservingFocus: Bool = false, selectRecordIDs: [String] = []) {
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
                inheritFocus(removedIDs: [focusedID], previousVisibleIDs: previousVisibleIDs)
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
            // Right-click inside a multi-selection targets the whole
            // selection (RecordTableView keeps it); outside, just this row.
            let selectedRows = tableView.selectedNavigableRows
            let targets = selectedRows.contains(row) ? records(atTableRows: selectedRows) : [record]
            let menu = NSMenu()
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveItem.submenu = makeMoveDestinationMenu(for: targets)
            menu.addItem(moveItem)
            menu.addItem(.separator())
            let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(moveToTrashFromMenu(_:)), keyEquivalent: "")
            trashItem.target = self
            trashItem.representedObject = targets.map(\.id)
            menu.addItem(trashItem)
            return menu
        }
    }

    private func popMoveMenu(forRows rowIndexes: IndexSet) {
        let targets = records(atTableRows: rowIndexes)
        guard !targets.isEmpty, let anchorRow = rowIndexes.first else { return }
        let menu = makeMoveDestinationMenu(for: targets)
        let rect = tableView.rect(ofRow: anchorRow)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 40, y: rect.midY), in: tableView)
    }

    private func makeMoveDestinationMenu(for targets: [Record]) -> NSMenu {
        let menu = NSMenu()
        let ids = targets.map(\.id)
        let inbox = NSMenuItem(title: "Inbox", action: #selector(moveRecordFromMenu(_:)), keyEquivalent: "")
        inbox.target = self
        inbox.representedObject = RecordMoveCommand(recordIDs: ids, projectID: nil)
        inbox.state = targets.allSatisfy { $0.projectID == nil } ? .on : .off
        menu.addItem(inbox)
        if !projects.isEmpty {
            menu.addItem(.separator())
        }
        for project in projects {
            let item = NSMenuItem(title: project.name, action: #selector(moveRecordFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RecordMoveCommand(recordIDs: ids, projectID: project.id)
            item.state = targets.allSatisfy { $0.projectID == project.id } ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func moveRecordFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? RecordMoveCommand else { return }
        moveRecords(ids: command.recordIDs, to: command.projectID)
    }

    private func moveRecords(ids: [String], to projectID: String?) {
        let moving = ids.filter { id in
            records.first(where: { $0.id == id })?.projectID != projectID
        }
        guard !moving.isEmpty else { return }

        performBatch(ids: moving, operation: { id, done in
            store.updateProject(id: id, projectID: projectID, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.presentPersistenceFailure(error: error)
                self.refreshVisibleSurface()
                return
            }
            self.applyMoveResult(recordIDs: moving, newProjectID: projectID)
        }
    }

    private func applyMoveResult(recordIDs: [String], newProjectID: String?) {
        let leavesCurrentScope: Bool
        switch currentScope {
        case .all:
            leavesCurrentScope = false
        case .project(let id):
            leavesCurrentScope = newProjectID != id
        }

        if leavesCurrentScope {
            let idSet = Set(recordIDs)
            let previousVisibleIDs = visibleRecords().map(\.id)
            records.removeAll { idSet.contains($0.id) }
            rebuildRowsAndReload()
            inheritFocus(removedIDs: recordIDs, previousVisibleIDs: previousVisibleIDs)
            return
        }

        for id in recordIDs {
            applyLocalRecordUpdate(id: id) { $0.projectID = newProjectID }
        }
        let destination: GroupID = newProjectID.map { .project($0) } ?? .inbox
        setGroupCollapsed(destination, collapsed: false)
        rebuildRowsAndReload()
        returnFocusToRecords(ids: recordIDs)
    }

    // MARK: - Drag to move (All View)

    private func draggedRecordIDs(from info: NSDraggingInfo) -> [String] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { $0.string(forType: RecordDragTypes.recordID) }
    }

    /// The group a proposed drop resolves to. `.above` a row belongs to the
    /// group of the row above the gap, so a drop just below a group's last
    /// row still targets that group.
    private func dropTargetGroup(forProposedRow row: Int, dropOperation: NSTableView.DropOperation) -> (headerRow: Int, groupID: GroupID)? {
        let candidate = dropOperation == .on ? row : row - 1
        return ListRowIndex.dropTargetGroup(forCandidateRow: candidate, in: rows)
    }

    private func projectID(for groupID: GroupID) -> String? {
        switch groupID {
        case .inbox: return nil
        case .project(let id): return id
        }
    }

    // MARK: - Move to Trash (PRD §8.8) and Undo

    private var isShowingTrash: Bool { !trashViewController.view.isHidden }

    private func moveSelectedRecordsToTrash(atRows rowIndexes: IndexSet) {
        guard editingRowIndex == nil else { return }
        let ids = records(atTableRows: rowIndexes).map(\.id)
        guard !ids.isEmpty else { return }
        moveRecordsToTrash(ids: ids)
    }

    @objc private func moveToTrashFromMenu(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], !ids.isEmpty else { return }
        moveRecordsToTrash(ids: ids)
    }

    /// A multi-select delete is one undo step: the whole batch registers a
    /// single undo action after every write commits, so ⌘Z restores all of
    /// it at once.
    private func moveRecordsToTrash(ids: [String]) {
        performBatch(ids: ids, operation: { id, done in
            store.moveToTrash(id: id, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.presentPersistenceFailure(error: error)
                self.refreshVisibleSurface()
                return
            }
            self.registerUndoRestore(ids: ids)
            self.applyMoveToTrashUI(recordIDs: ids)
        }
    }

    /// Inverse of `moveRecordsToTrash`, invoked by UndoManager. Registers the
    /// redo action synchronously while `isUndoing` is still true — the store
    /// write itself is async and must not be the place that re-registers.
    private func restoreRecordsFromTrashForUndo(ids: [String]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.moveRecordsToTrashForRedo(ids: ids)
        }
        undoManager?.setActionName("Move to Trash")
        performBatch(ids: ids, operation: { id, done in
            store.restoreFromTrash(id: id) { done($0.map { _ in () }) }
        }) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.refreshVisibleSurface()
                return
            }
            self.applyRestoreUI(recordIDs: ids)
        }
    }

    private func moveRecordsToTrashForRedo(ids: [String]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRecordsFromTrashForUndo(ids: ids)
        }
        undoManager?.setActionName("Move to Trash")
        performBatch(ids: ids, operation: { id, done in
            store.moveToTrash(id: id, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.presentPersistenceFailure(error: error)
                self.refreshVisibleSurface()
                return
            }
            self.applyMoveToTrashUI(recordIDs: ids)
        }
    }

    private func registerUndoRestore(ids: [String]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRecordsFromTrashForUndo(ids: ids)
        }
        undoManager?.setActionName("Move to Trash")
    }

    private func applyMoveToTrashUI(recordIDs: [String]) {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
            return
        }
        let idSet = Set(recordIDs)
        let previousVisibleIDs = visibleRecords().map(\.id)
        records.removeAll { idSet.contains($0.id) }
        rebuildRowsAndReload()
        inheritFocus(removedIDs: recordIDs, previousVisibleIDs: previousVisibleIDs)
    }

    private func applyRestoreUI(recordIDs: [String]) {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
            return
        }
        performSearch(term: inputField.stringValue, preservingFocus: true, selectRecordIDs: recordIDs)
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

    func smokeRowHeight(forRecordID id: String) -> CGFloat? {
        guard let row = tableRow(forRecordID: id) else { return nil }
        tableView.scrollRowToVisible(row)
        _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        tableView.layoutSubtreeIfNeeded()
        return tableView.rect(ofRow: row).height
    }

    var smokeInputCapsuleFrame: NSRect { universalInput.frame }
    var smokeScopeBarHeight: CGFloat { scopeBar.frame.height }
    var smokeScopeBarFrame: NSRect { scopeBar.frame }
    var smokeScopeBarScrollFrame: NSRect {
        scopeBar.convert(scopeBar.smokeScrollFrame, to: mainSurface)
    }
    var smokeAllChipFrame: NSRect? { scopeBar.smokeAllChipFrame(in: mainSurface) }
    var smokeAllChipFrameInWindow: NSRect? { scopeBar.smokeAllChipFrame(in: nil) }
    var smokeSelectedScopeChipTextColor: NSColor? { scopeBar.smokeSelectedChipForegroundColor() }

    var smokeFirstGroupHeaderFrameInWindow: NSRect? {
        for row in 0..<tableView.numberOfRows {
            guard case .groupHeader = rows[row] else { continue }
            tableView.scrollRowToVisible(row)
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
            _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            tableView.layoutSubtreeIfNeeded()
            return tableView.convert(tableView.rect(ofRow: row), to: nil)
        }
        return nil
    }

    var smokeFirstGroupCollapsed: Bool? {
        for row in rows {
            if case .groupHeader(_, _, let collapsed) = row { return collapsed }
        }
        return nil
    }
}

private final class RecordMoveCommand: NSObject {
    let recordIDs: [String]
    let projectID: String?

    init(recordIDs: [String], projectID: String?) {
        self.recordIDs = recordIDs
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

    /// Multi-select filter: only Record rows can enter the selection —
    /// covers clicks, ⇧clicks, ⌘clicks, and rubber-band drags in one place
    /// (with this implemented, `shouldSelectRow` would not be consulted).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { record(atTableRow: $0) != nil })
    }

    // MARK: - Drag to move (All View only)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard isGrouped, let record = record(atTableRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(record.id, forType: RecordDragTypes.recordID)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard isGrouped,
              let target = dropTargetGroup(forProposedRow: row, dropOperation: dropOperation) else { return [] }
        let ids = draggedRecordIDs(from: info)
        guard !ids.isEmpty else { return [] }
        let destinationProjectID = projectID(for: target.groupID)
        // Every dragged Record already lives in the target group → nothing
        // to move, don't light up the drop.
        guard ids.contains(where: { id in
            records.first(where: { $0.id == id })?.projectID != destinationProjectID
        }) else { return [] }
        // Retarget onto the group header so the whole group highlights as
        // one drop target — there is no manual order inside a group to hit.
        tableView.setDropRow(target.headerRow, dropOperation: .on)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard isGrouped,
              let target = dropTargetGroup(forProposedRow: row, dropOperation: dropOperation) else { return false }
        let ids = draggedRecordIDs(from: info)
        guard !ids.isEmpty else { return false }
        moveRecords(ids: ids, to: projectID(for: target.groupID))
        return true
    }
}
