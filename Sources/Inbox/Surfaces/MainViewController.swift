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
    /// Window-level undo stack for Move / Resolve / Move to Trash. Field
    /// editors keep their own undo managers, so typing Undo does not mix
    /// with this stack.
    private let deleteUndoManager = UndoManager()

    let mainSurface = NSView()
    let universalInput = UniversalInputView()
    var inputField: NSTextField { universalInput.textField }
    let scopeBar = ScopeBarView()
    let tableView = RecordTableView()
    let scrollView = OverlayScrollView()
    /// The one hard line on the surface (ui.md §3), between Input and the
    /// Scope Bar; the list's other edges dissolve under the bars instead.
    // 实验（未提交）：底部溶解带关闭（原 bottomBar: utilityBarHeight）——
    // 让列表全不透明地从玻璃 ButtonGroup 下穿过，由玻璃负责区隔。
    private(set) lazy var listDissolve = EdgeDissolve(scrollView: scrollView, topBar: Theme.Size.scopeBarHeight, bottomBar: 0)
    /// Bottom-bar controls are the same custom chip as the Scope Bar, on
    /// purpose: measured against platform accessory-bar NSButtons the chip
    /// paints ~3–8 ms faster on first draw and ~2 ms per redraw each, and
    /// it is maintained for the Scope Bar anyway (HISTORY 性能基线).
    let utilityBar = NSView()
    let resolvedChip = ScopeChipButton(title: "")
    let sortChip = ScopeChipButton(title: "")
    /// Weak "N conflicts" badge (PRD §15.3); hidden while the count is 0.
    /// Clicking filters the list to the conflict pairs and back.
    let conflictsChip = ScopeChipButton(title: "")
    let offlineNoticeLabel = NSTextField(labelWithString: "iCloud unavailable · offline")
    let trashButton = ScopeChipButton(title: "")
    /// Function group of the utility bar (ui.md §5): icon buttons in a
    /// stack, so a hidden Conflicts chip leaves no gap behind.
    let functionGroup = NSStackView()

    var records: [Record] = []
    /// Both halves of every unresolved conflict pair in `records` (PRD
    /// §15.3): the marked duplicates plus the originals they point at.
    /// Derived in `rebuildRows()`, so a reload is the only way it changes.
    var conflictPairIDs: Set<String> = []
    /// Table rows derived from `records` + `projects` + collapse state.
    /// Every row↔record conversion goes through `ListRowIndex` on this array.
    var rows: [ListRow] = []
    /// Bumped by every search and by Inline Edit, so a stale completion can
    /// never reload the table out from under the user.
    var searchGeneration = 0
    /// Generation of the last search whose completion was applied; equals
    /// `searchGeneration` when nothing is in flight (smoke waits on it).
    private(set) var settledSearchGeneration = 0

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
    /// Conflicts-chip filter. Session state only — a pending conflict is
    /// not a preference, so it is never persisted.
    var showOnlyConflicts = false

    /// Non-nil while a row's Content is in Inline Edit (PRD §8.5). This is
    /// the third focus state beyond Input Focus / Row Focus. It is a table
    /// row index, never a `records` array index — convert via `record(atTableRow:)`.
    var editingRowIndex: Int?
    /// Fitting height of the row being edited, updated on every keystroke
    /// (`RecordCellView.onEditingHeightChanged`); read by `heightOfRow`.
    var editingRowHeight: CGFloat?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("RecordCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")

    init(store: RecordStore) {
        self.store = store
        self.trashViewController = TrashViewController(store: store)
        super.init(nibName: nil, bundle: nil)
        // Registrations land in async store completions, so event-based
        // grouping is meaningless here and merged steps under a nested run
        // loop (Resolve + Trash became one ⌘Z in --ui-smoke). Every action
        // opens and closes its own group in `registerUndoStep`.
        deleteUndoManager.groupsByEvent = false
    }

    override var undoManager: UndoManager? {
        deleteUndoManager
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // 实验（未提交）：clear 玻璃整窗背景，对照原 sidebar behind-window 模糊。
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Theme.Size.windowDefault))
            glass.style = .clear
            // 实验（未提交）：窗口圆角自绘——窗口本身透明，可见形状就是这层
            // 玻璃（NSWindow 无公开圆角 API），改这个数值即改"窗口圆角"，
            // 阴影按像素形状自动跟随。代价：根视图需要裁剪，Input 玻璃出界的
            // 投影在窗缘会被裁掉（实验期接受）。
            let windowCornerRadius: CGFloat = 28
            glass.cornerRadius = windowCornerRadius
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = windowCornerRadius
            glass.clipsToBounds = true
            // Siri 风格暗色 scrim。CAGradientLayer 色标间只做线性插值，
            // 平滑靠"曲线采样成密集色标"（easing-gradient 手法）：每段
            // smoothstep（两端斜率 0），拐点与收尾都没有折线。
            // 锚点（可调）：顶 0.8 → 0.8 处 0.6 → 底 0.2。
            let anchors: [(location: CGFloat, alpha: CGFloat)] = [
                (0.0, 0.9),
                (0.7, 0.7),
                (1.0, 0.2)
            ]
            func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
            var colors: [CGColor] = []
            var locations: [NSNumber] = []
            for (a, b) in zip(anchors, anchors.dropFirst()) {
                let steps = 12
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let alpha = a.alpha + (b.alpha - a.alpha) * smoothstep(t)
                    colors.append(NSColor.black.withAlphaComponent(alpha).cgColor)
                    locations.append(NSNumber(value: a.location + (b.location - a.location) * t))
                }
            }
            let gradient = CAGradientLayer()
            gradient.colors = colors
            gradient.locations = locations
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            let scrim = NSView(frame: glass.bounds)
            scrim.layer = gradient
            scrim.wantsLayer = true
            scrim.autoresizingMask = [.width, .height]
            glass.addSubview(scrim)
            view = glass
            return
        }
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Theme.Size.windowDefault))
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

    override func viewDidLayout() {
        super.viewDidLayout()
        listDissolve.update()
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
        // instead of All's capsule edge. Full width puts the list rail on
        // the same window x as the chip.
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        // Explicit heights (see heightOfRow): automatic row heights reset
        // every row to an estimate on reloadData and re-measure lazily,
        // which jumped the scroll offset, never shrank a row, and dropped
        // the selection on resize.
        tableView.usesAutomaticRowHeights = false
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
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.onRequestBeginInlineEdit = { [weak self] row in
            self?.beginInlineEdit(atRow: row)
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
        // The bars overlay the list's ends (ui.md §4): content rests just
        // inside them and the overlay scroller stays clear of both.
        let barInsets = NSEdgeInsets(top: Theme.Size.scopeBarHeight, left: 0, bottom: Theme.Size.utilityBarHeight, right: 0)
        scrollView.contentInsets = barInsets
        scrollView.scrollerInsets = barInsets
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
        resolvedChip.setContentHuggingPriority(.required, for: .horizontal)

        applySortChipSymbol()
        sortChip.onClick = { [weak self] in self?.toggleSort() }
        sortChip.setContentHuggingPriority(.required, for: .horizontal)

        conflictsChip.symbolName = "exclamationmark.triangle"
        conflictsChip.isHidden = true
        conflictsChip.onClick = { [weak self] in self?.toggleShowOnlyConflicts() }
        conflictsChip.setContentHuggingPriority(.required, for: .horizontal)

        trashButton.symbolName = "trash"
        trashButton.toolTip = "Trash"
        trashButton.setAccessibilityLabel("Trash")
        trashButton.onClick = { [weak self] in self?.openTrash() }
        trashButton.setContentHuggingPriority(.required, for: .horizontal)

        offlineNoticeLabel.font = .systemFont(ofSize: 11)
        offlineNoticeLabel.textColor = .secondaryLabelColor
        offlineNoticeLabel.isHidden = true
        offlineNoticeLabel.setContentHuggingPriority(.required, for: .horizontal)
        offlineNoticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        functionGroup.orientation = .horizontal
        functionGroup.alignment = .centerY
        functionGroup.spacing = Theme.Spacing.xs
        functionGroup.translatesAutoresizingMaskIntoConstraints = false
        // Resolved / Sort / Trash are square icon buttons; Conflicts keeps
        // its count as text because it only appears when there is news.
        for chip in [resolvedChip, sortChip, trashButton] {
            chip.iconOnly = true
        }
        // 实验（未提交）：ButtonGroup——玻璃胶囊容器，成员无底、hover 圆底。
        for chip in [resolvedChip, sortChip, conflictsChip, trashButton] {
            chip.style = .grouped
            functionGroup.addArrangedSubview(chip)
        }

        // 实验（未提交）：ButtonGroup 玻璃胶囊（clear + 黑 tint，会随背景
        // 取样——玻璃本性，定稿决策）。
        let buttonGroup = GlassCapsuleView()
        buttonGroup.prefersClearGlass = true
        buttonGroup.tintColor = NSColor.black.withAlphaComponent(0.4)
        buttonGroup.translatesAutoresizingMaskIntoConstraints = false
        buttonGroup.contentView.addSubview(functionGroup)

        offlineNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        utilityBar.translatesAutoresizingMaskIntoConstraints = false
        utilityBar.addSubview(buttonGroup)
        utilityBar.addSubview(offlineNoticeLabel)

        NSLayoutConstraint.activate([
            // 容器尺寸由成员反推（玻璃视图自身不传递内部约束）：
            // 左右各 4，高 26 + 上下各 4 = 34。
            buttonGroup.widthAnchor.constraint(equalTo: functionGroup.widthAnchor, constant: 8),
            buttonGroup.heightAnchor.constraint(equalToConstant: Theme.Size.chipHeight + 8),
            functionGroup.centerXAnchor.constraint(equalTo: buttonGroup.centerXAnchor),
            functionGroup.centerYAnchor.constraint(equalTo: buttonGroup.centerYAnchor),

            buttonGroup.leadingAnchor.constraint(equalTo: utilityBar.leadingAnchor, constant: Theme.Size.windowInset),
            buttonGroup.bottomAnchor.constraint(equalTo: utilityBar.bottomAnchor, constant: -Theme.Size.windowInset),

            offlineNoticeLabel.trailingAnchor.constraint(equalTo: utilityBar.trailingAnchor, constant: -Theme.Size.windowInset),
            offlineNoticeLabel.centerYAnchor.constraint(equalTo: buttonGroup.centerYAnchor),
            offlineNoticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: buttonGroup.trailingAnchor, constant: Theme.Spacing.xl)
        ])
    }

    /// The sort button shows what the list is sorted by; clicking flips it.
    private func applySortChipSymbol() {
        sortChip.symbolName = sortOrder == .newestFirst ? "clock" : "flag"
        sortChip.toolTip = "Sorted by \(sortOrder.chipTitle) — click for \(sortOrder.next.chipTitle)"
        sortChip.setAccessibilityLabel("Sort by \(sortOrder.next.chipTitle)")
        sortChip.setAccessibilityValue(sortOrder.chipTitle)
    }

    func showOfflineNotice(_ visible: Bool) {
        offlineNoticeLabel.isHidden = !visible
    }

    private func applyResolvedChipSymbol() {
        resolvedChip.symbolName = showResolved ? "eye" : "eye.slash"
        resolvedChip.toolTip = showResolved ? "Hide Resolved" : "Show Resolved"
        resolvedChip.setAccessibilityLabel(resolvedChip.toolTip)
        resolvedChip.setAccessibilityValue(showResolved ? "on" : "off")
    }

    private func toggleShowResolved() {
        showResolved.toggle()
        applyResolvedChipSymbol()
        Preferences.showResolved = showResolved
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    private func toggleShowOnlyConflicts() {
        showOnlyConflicts.toggle()
        conflictsChip.isSelectedScope = showOnlyConflicts
        conflictsChip.setAccessibilityValue(showOnlyConflicts ? "on" : "off")
        performSearch(term: inputField.stringValue, preservingFocus: true)
    }

    /// Re-counts after every list reload (an indexed query, cheap enough
    /// to not be worth caching). Reaching 0 while the filter is on switches
    /// it off and re-searches, so the list never ends up empty for no
    /// visible reason.
    func refreshConflictsChip() {
        store.listConflicts { [weak self] result in
            guard let self, case .success(let conflicts) = result else { return }
            let count = conflicts.count
            self.conflictsChip.chipTitle = "\(count) conflict\(count == 1 ? "" : "s")"
            self.conflictsChip.isHidden = count == 0
            if count == 0, self.showOnlyConflicts {
                self.toggleShowOnlyConflicts()
            }
        }
    }

    /// The sort chip is a two-state toggle (Newest ⇄ Priority); no menu.
    func toggleSort() {
        sortOrder = sortOrder.next
        applySortChipSymbol()
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

        // The list spans Input→bottom and goes in first; the Scope Bar
        // and utility bar are transparent overlays over its ends (ui.md
        // §4). Input last so its glass shadow paints over the Scope Bar.
        mainSurface.addSubview(scrollView)
        mainSurface.addSubview(scopeBar)
        mainSurface.addSubview(utilityBar)
        mainSurface.addSubview(universalInput)

        NSLayoutConstraint.activate([
            // 实验（未提交）：toolbar 撑高了 safe area，Input 改锚窗口顶固定
            // 36pt（≈ 原 titlebar 28 + md 8），与 toolbar 高度解耦。
            universalInput.topAnchor.constraint(equalTo: view.topAnchor, constant: 48),
            universalInput.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor, constant: Theme.Size.windowInset),
            universalInput.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor, constant: -Theme.Size.windowInset),
            universalInput.heightAnchor.constraint(equalToConstant: Theme.Size.inputHeight),

            scrollView.topAnchor.constraint(equalTo: universalInput.bottomAnchor, constant: Theme.Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: mainSurface.bottomAnchor),

            scopeBar.topAnchor.constraint(equalTo: universalInput.bottomAnchor, constant: Theme.Spacing.md),
            scopeBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            scopeBar.heightAnchor.constraint(equalToConstant: Theme.Size.scopeBarHeight),

            utilityBar.leadingAnchor.constraint(equalTo: mainSurface.leadingAnchor),
            utilityBar.trailingAnchor.constraint(equalTo: mainSurface.trailingAnchor),
            utilityBar.bottomAnchor.constraint(equalTo: mainSurface.bottomAnchor),
            utilityBar.heightAnchor.constraint(equalToConstant: Theme.Size.utilityBarHeight)
        ])
        listDissolve.update()
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
        // Selection is Row Focus state; an inactive (grey) highlight left
        // behind under Input Focus has no function and reads as a stray.
        tableView.deselectAll(nil)
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
            includeResolved: showResolved,
            onlyConflicts: showOnlyConflicts
        ) { [weak self] result, token in
            guard let self, token == self.searchGeneration else { return }
            self.settledSearchGeneration = token
            if case .success(let records) = result {
                self.records = records
                self.rebuildRowsAndReload()
                self.refreshConflictsChip()
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
        conflictPairIDs = records.reduce(into: Set<String>()) { ids, record in
            guard let originalID = record.conflictOf else { return }
            ids.insert(record.id)
            ids.insert(originalID)
        }
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
        refreshVisibleSurface(selecting: [])
    }

    /// Re-syncs from the DB and, on the main surface, puts Focus on `ids`
    /// if they are visible (undo brings rows back where they were).
    func refreshVisibleSurface(selecting ids: [String]) {
        if isShowingTrash {
            trashViewController.reload(projects: projects)
        } else {
            performSearch(term: inputField.stringValue, preservingFocus: true, selectRecordIDs: ids)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension MainViewController: NSTextFieldDelegate {
    /// A mouse click into Universal Input bypasses `focusInputAtEnd`; clear
    /// the Row Focus selection here too.
    func controlTextDidBeginEditing(_ obj: Notification) {
        tableView.deselectAll(nil)
    }

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

    /// Exact row heights from the cell's own measurement; the row being
    /// edited follows its field editor instead.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .groupHeader:
            return Theme.Size.groupHeaderHeight
        case .record(let record):
            // Asking the table for the cell here would re-enter the delegate;
            // the editing height is pushed in by the cell instead.
            if row == editingRowIndex, let editingRowHeight, editingRowHeight > 0 {
                return editingRowHeight
            }
            return RecordCellView.displayHeight(for: record, style: .regular, tableWidth: tableView.bounds.width)
        }
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
            cell.configure(with: record, isConflicted: conflictPairIDs.contains(record.id))
            return cell
        }
    }

    /// Multi-select filter: only Record rows can enter the selection —
    /// covers clicks, ⇧clicks, ⌘clicks, and rubber-band drags in one place
    /// (with this implemented, `shouldSelectRow` would not be consulted).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { record(atTableRow: $0) != nil })
    }

    /// A click on a row moves first responder and the selection in one go;
    /// this is the one hook both share.
    func tableViewSelectionDidChange(_ notification: Notification) {
    }
}

