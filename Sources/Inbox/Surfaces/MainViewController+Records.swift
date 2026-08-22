import AppKit

/// Record actions on the main surface. Each one writes through the
/// store, then patches the local `records`/`rows` and decides where
/// Focus lands (PRD §8). Failures re-sync from the DB.
extension MainViewController {
    // MARK: - Create

    func handleCreate() {
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
        Dialogs.persistenceFailure(error)
        focusInputAtEnd()
    }

    // MARK: - Row Focus: Priority (PRD §8.4)

    func adjustPriority(atRows rowIndexes: IndexSet, adjustment: PriorityAdjustment) {
        let selected = records(atTableRows: rowIndexes)
        // Each Record clamps at its own boundary; ones already at P0/P3
        // stay put while the rest move one step.
        let targets = selected.compactMap { record -> (id: String, priority: Priority)? in
            let newPriority = adjustment.apply(to: record.priorityValue)
            return newPriority == record.priorityValue ? nil : (record.id, newPriority)
        }
        guard !targets.isEmpty else { return }
        let selectedIDs = selected.map(\.id)

        RecordStore.batch(ids: targets.map(\.id), operation: { id, done in
            guard let priority = targets.first(where: { $0.id == id })?.priority else { return }
            store.updatePriority(id: id, priority: priority.rawValue, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
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
    func toggleResolve(atRows rowIndexes: IndexSet) {
        let selected = records(atTableRows: rowIndexes)
        guard !selected.isEmpty else { return }
        let openIDs = selected.filter { $0.status == RecordStatus.open.rawValue }.map(\.id)
        let willResolve = !openIDs.isEmpty
        let targetIDs = willResolve ? openIDs : selected.map(\.id)
        let newStatus: RecordStatus = willResolve ? .resolved : .open

        RecordStore.batch(ids: targetIDs, operation: { id, done in
            store.setStatus(id: id, status: newStatus, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
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

    // MARK: - Copy (⌘C)

    /// Puts the selected Records' Content on the general pasteboard, one
    /// Record per line in display order.
    func copyRecords(atRows rowIndexes: IndexSet) {
        let contents = records(atTableRows: rowIndexes).map(\.content)
        guard !contents.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Row Focus: Inline Edit (PRD §8.5)

    func beginInlineEdit(atRow row: Int) {
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
        cell.onEditingHeightChanged = { [weak self] in
            guard let self, self.editingRowIndex == row else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
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
                    Dialogs.persistenceFailure(error)
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
                cell.configure(with: record)
            }
            cell.endEditing()
            cell.onEditingEnded = nil
            cell.onEditingHeightChanged = nil
        }
        if returnFocus {
            returnFocusToRow(row)
        }
        // The row grew with the editor's text. `noteHeightOfRows` (even after
        // a single-row reload) never shrinks an automatic-height row back,
        // so reload the table; selection is re-applied by index.
        let selected = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selected, byExtendingSelection: false)
    }

    // MARK: - Move Record (PRD §8.7)

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .groupHeader(let id, _, _):
            guard case .project(let projectID) = id else { return nil }
            return projectAdminMenu(projectID: projectID)
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

    func popMoveMenu(forRows rowIndexes: IndexSet) {
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

    func moveRecords(ids: [String], to projectID: String?) {
        let moving = ids.filter { id in
            records.first(where: { $0.id == id })?.projectID != projectID
        }
        guard !moving.isEmpty else { return }

        RecordStore.batch(ids: moving, operation: { id, done in
            store.updateProject(id: id, projectID: projectID, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
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
        Preferences.setGroupCollapsed(destination, false)
        rebuildRowsAndReload()
        returnFocusToRecords(ids: recordIDs)
    }

    // MARK: - Move to Trash (PRD §8.8) and Undo

    func moveSelectedRecordsToTrash(atRows rowIndexes: IndexSet) {
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
        RecordStore.batch(ids: ids, operation: { id, done in
            store.moveToTrash(id: id, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
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
        RecordStore.batch(ids: ids, operation: { id, done in
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
        RecordStore.batch(ids: ids, operation: { id, done in
            store.moveToTrash(id: id, completion: done)
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                Dialogs.persistenceFailure(error)
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
}

private final class RecordMoveCommand: NSObject {
    let recordIDs: [String]
    let projectID: String?

    init(recordIDs: [String], projectID: String?) {
        self.recordIDs = recordIDs
        self.projectID = projectID
    }
}
