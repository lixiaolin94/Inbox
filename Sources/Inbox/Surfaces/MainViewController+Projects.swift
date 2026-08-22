import AppKit

/// Project list, Scope, Project admin, and drag-to-move on the main
/// surface (PRD §7, §9). Every Project-list change funnels through
/// `reloadProjectsAndSearch`.
extension MainViewController {
    // MARK: - Project list and Scope (PRD §6.6, §7, §9)

    /// First load: restore the last Scope, then let `reloadProjects` drop
    /// it back to All if that Project no longer exists (PRD §7.1).
    func loadProjectsAndRestoreScope() {
        currentScope = Preferences.lastScopeProjectID.map { .project(id: $0) } ?? .all
        reloadProjectsAndSearch()
    }

    /// The single refresh path after anything changes the Project list —
    /// create / rename / delete / reorder here, or a remote sync. Re-reads
    /// the list, validates the Scope, refreshes the Scope Bar and the Go
    /// menu, then re-runs the search keeping selection and focus.
    func reloadProjectsAndSearch() {
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
            case .failure(let error):
                Dialogs.persistenceFailure(error)
            }
            self.performSearch(term: self.inputField.stringValue, preservingFocus: true)
        }
    }

    private func persistCurrentScope() {
        Preferences.lastScopeProjectID = currentScope.createTargetProjectID
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
        scopeBar.selectScope(scope)
        performSearch(term: inputField.stringValue)
    }

    // MARK: - Project Create / Rename / Delete / Reorder (PRD §7.5)

    /// Scope Bar "+". Modal by nature — the "must not steal Input focus"
    /// rule is specific to Scope *selection* clicks, not this deliberate,
    /// self-contained creation flow — so focus is explicitly returned to
    /// Input afterward.
    func promptCreateProject() {
        defer { focusInputAtEnd() }
        guard let name = Dialogs.promptName(title: "New Project", confirm: "Create", placeholder: "Project name") else { return }
        store.projects.createProject(name: name) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                Dialogs.persistenceFailure(error)
            }
            self.reloadProjectsAndSearch()
        }
    }

    func reorderProjects(_ orderedIDs: [String]) {
        store.projects.reorderProjects(orderedIDs: orderedIDs) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                Dialogs.persistenceFailure(error)
            }
            self.reloadProjectsAndSearch()
        }
    }

    func projectAdminMenu(projectID: String) -> NSMenu {
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
        defer { focusInputAtEnd() }
        guard let name = Dialogs.promptName(title: "Rename Project", confirm: "Rename", initial: project.name),
              name != project.name else { return }
        store.projects.renameProject(id: project.id, name: name) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                Dialogs.persistenceFailure(error)
            }
            self.reloadProjectsAndSearch()
        }
    }

    private func confirmDeleteProject(_ project: Project) {
        defer { focusInputAtEnd() }
        guard Dialogs.confirmDeleteProject(named: project.name) else { return }
        store.projects.deleteProject(id: project.id) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                Dialogs.persistenceFailure(error)
            }
            self.reloadProjectsAndSearch()
        }
    }

    // MARK: - Drag to move (All View only, PRD §8.7 drag UI)

    private func draggedRecordIDs(from info: NSDraggingInfo) -> [String] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { $0.string(forType: RecordDragTypes.recordID) }
    }

    /// The group a proposed drop resolves to. `.above` a row belongs to the
    /// group of the row above the gap, so a drop just below a group's last
    /// row still targets that group.
    private func dropTargetGroup(forProposedRow row: Int, dropOperation: NSTableView.DropOperation) -> (headerRow: Int?, groupID: GroupID)? {
        let candidate = dropOperation == .on ? row : row - 1
        return ListRowIndex.dropTargetGroup(forCandidateRow: candidate, in: rows)
    }

    private func projectID(for groupID: GroupID) -> String? {
        switch groupID {
        case .inbox: return nil
        case .project(let id): return id
        }
    }

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
        // Project groups highlight the header as one drop target. The
        // headerless Inbox region keeps the proposed gap/row.
        if let headerRow = target.headerRow {
            tableView.setDropRow(headerRow, dropOperation: .on)
        }
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
