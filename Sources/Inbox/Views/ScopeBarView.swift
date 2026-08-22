import AppKit

/// `All | Project 1 | …` scrolling horizontally, with "+" fixed at the
/// trailing edge outside the scroll view. When the row overflows, both
/// ends of the scroller fade out to hint at more Scopes off-screen.
final class ScopeBarView: NSView {
    var onSelectScope: ((Scope) -> Void)?
    var onCreateProject: (() -> Void)?
    var onReorderProjects: (([String]) -> Void)?
    var onBuildProjectMenu: ((String) -> NSMenu?)?
    var onDropRecords: (([String], String?) -> Void)?

    static var chipRowInset: CGFloat { Theme.Size.contentInset }

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let addButton = ScopeChipButton(title: "")
    private let edgeMask = CAGradientLayer()
    private static let edgeFade: CGFloat = 20
    private var chips: [(scope: Scope, button: ScopeChipButton)] = []

    private var currentScope: Scope = .all

    private var dragChip: ScopeChipButton?
    private var dragProjectID: String?
    private var dragGrabOffset: CGPoint = .zero
    private var orderAtDragStart: [String] = []
    private var dragIndicator: NSImageView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setUp() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.Size.chipSpacing
        // Trailing inset equals the fade so the last chip can rest clear of it.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.chipRowInset, bottom: 0, right: Self.edgeFade)
        stack.translatesAutoresizingMaskIntoConstraints = false

        clipsToBounds = false

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.usesPredominantAxisScrolling = true
        scrollView.wantsLayer = true
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        addButton.prefersSquare = true
        addButton.symbolName = "plus"
        addButton.toolTip = "New Project"
        addButton.setAccessibilityLabel("New Project")
        addButton.onClick = { [weak self] in self?.onCreateProject?() }
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateEdgeMask),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -Theme.Size.chipSpacing),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Size.contentInset),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
    }

    func selectScope(_ scope: Scope) {
        currentScope = scope
        for (chipScope, button) in chips {
            button.isSelectedScope = chipScope == scope
        }
        scrollSelectionIntoView()
    }

    func update(scope: Scope, projects: [Project]) {
        currentScope = scope
        abortChipDrag()

        // Reuse map is derived from `chips` (the one list the drag-reorder
        // path mutates) and keyed on the project id because Scope is not
        // Hashable. A button is only ever reused for the same Scope, so the
        // `projectID` its closures captured at creation stays correct.
        var existing: [String?: ScopeChipButton] = [:]
        for (chipScope, button) in chips {
            existing[chipScope.createTargetProjectID] = button
        }
        chips.removeAll(keepingCapacity: true)

        let allButton = existing.removeValue(forKey: nil) ?? makeChip(title: "All") { [weak self] in
            self?.onSelectScope?(.all)
        }
        allButton.isSelectedScope = scope == .all
        chips.append((.all, allButton))

        for project in projects {
            let projectScope = Scope.project(id: project.id)
            let button = existing.removeValue(forKey: project.id) ?? makeProjectChip(projectID: project.id, name: project.name)
            button.chipTitle = project.name
            button.isSelectedScope = scope == projectScope
            chips.append((projectScope, button))
        }

        for orphan in existing.values {
            stack.removeArrangedSubview(orphan)
            orphan.removeFromSuperview()
        }

        let target = chips.map(\.button)
        if !stack.arrangedSubviews.elementsEqual(target, by: ===) {
            stack.arrangedSubviews.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            target.forEach(stack.addArrangedSubview)
        }

        // Scroll once the scroll view has a real width; doing it now (width
        // may still be 0) would pin the clip origin to the chip's x.
        needsScrollToSelection = true
        needsLayout = true
        // Chip frames are read right after update (smoke, drag reorder);
        // settle them now instead of at the next run-loop turn.
        layoutSubtreeIfNeeded()
    }

    private var needsScrollToSelection = false

    override func layout() {
        super.layout()
        if needsScrollToSelection, scrollView.bounds.width > 0 {
            needsScrollToSelection = false
            scrollSelectionIntoView()
        }
        updateEdgeMask()
    }

    /// Pure function of content width vs. visible width and scroll offset;
    /// never changes layout, so scrolling cannot feed back into itself.
    @objc private func updateEdgeMask() {
        let visible = scrollView.bounds.width
        guard visible > 0, stack.fittingSize.width > visible + 0.5 else {
            scrollView.layer?.mask = nil
            return
        }
        let fade = Self.edgeFade / visible
        let leadIn = scrollView.contentView.bounds.origin.x > 0.5 ? fade : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = scrollView.bounds
        edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        edgeMask.locations = [0, NSNumber(value: Double(leadIn)), NSNumber(value: Double(1 - fade)), 1]
        scrollView.layer?.mask = edgeMask
        CATransaction.commit()
    }

    private func scrollSelectionIntoView() {
        guard let index = chips.firstIndex(where: { $0.scope == currentScope }) else { return }
        stack.layoutSubtreeIfNeeded()
        if index == 0 {
            // "All": rest at the origin rather than letting scrollToVisible
            // clamp the clip onto the chip (which hid the 16pt row inset).
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            stack.scrollToVisible(chips[index].button.frame.insetBy(dx: -Self.chipRowInset, dy: 0))
        }
    }

    private func makeChip(title: String, action: @escaping () -> Void) -> ScopeChipButton {
        let button = ScopeChipButton(title: title)
        button.onClick = action
        return button
    }

    private func makeProjectChip(projectID: String, name: String) -> ScopeChipButton {
        let button = makeChip(title: name) { [weak self] in
            self?.onSelectScope?(.project(id: projectID))
        }
        button.isDraggable = true
        button.onBeginDrag = { [weak self, weak button] windowPoint in
            guard let self, let button else { return }
            self.beginChipDrag(projectID: projectID, chip: button, windowPoint: windowPoint)
        }
        button.onDraggedTo = { [weak self] windowPoint in
            self?.updateChipDrag(windowPoint: windowPoint)
        }
        button.onEndDrag = { [weak self] in
            self?.endChipDrag()
        }
        button.onBuildMenu = { [weak self] in
            self?.onBuildProjectMenu?(projectID)
        }
        button.isDropTarget = true
        button.onDropRecords = { [weak self] ids in
            self?.onDropRecords?(ids, projectID)
        }
        return button
    }

    // MARK: - Drag reorder (PRD §7.4)

    private func projectIDsInBar() -> [String] {
        chips.compactMap { item in
            if case .project(let id) = item.scope { return id }
            return nil
        }
    }

    private func beginChipDrag(projectID: String, chip: ScopeChipButton, windowPoint: NSPoint) {
        dragChip = chip
        dragProjectID = projectID
        orderAtDragStart = projectIDsInBar()
        let chipFrameInWindow = chip.convert(chip.bounds, to: nil)
        dragGrabOffset = CGPoint(
            x: windowPoint.x - chipFrameInWindow.origin.x,
            y: windowPoint.y - chipFrameInWindow.origin.y
        )
        chip.alphaValue = 0.35
        if let image = snapshot(chip) {
            let indicator = NSImageView(image: image)
            indicator.wantsLayer = true
            indicator.alphaValue = 0.7
            indicator.translatesAutoresizingMaskIntoConstraints = true
            indicator.frame.size = chip.bounds.size
            addSubview(indicator)
            dragIndicator = indicator
            positionIndicator(windowPoint: windowPoint)
        }
    }

    private func updateChipDrag(windowPoint: NSPoint) {
        positionIndicator(windowPoint: windowPoint)
        guard let dragProjectID else { return }

        let pointInStack = stack.convert(windowPoint, from: nil)
        let projectChips = chips.compactMap { item -> (String, ScopeChipButton)? in
            if case .project(let id) = item.scope { return (id, item.button) }
            return nil
        }
        guard let current = projectChips.firstIndex(where: { $0.0 == dragProjectID }) else { return }

        var destination = current
        for (index, (_, button)) in projectChips.enumerated() {
            if pointInStack.x < button.frame.midX {
                destination = index
                break
            }
            destination = index
        }
        if destination != current {
            moveProjectChip(from: current, to: destination)
        }
    }

    private func endChipDrag() {
        let newOrder = projectIDsInBar()
        let started = orderAtDragStart
        abortChipDrag()
        if newOrder != started {
            onReorderProjects?(newOrder)
        }
    }

    private func abortChipDrag() {
        dragChip?.alphaValue = 1
        dragIndicator?.removeFromSuperview()
        dragIndicator = nil
        dragChip = nil
        dragProjectID = nil
        orderAtDragStart = []
    }

    private func moveProjectChip(from: Int, to: Int) {
        let fromChipIndex = from + 1
        let toChipIndex = to + 1
        let item = chips.remove(at: fromChipIndex)
        chips.insert(item, at: toChipIndex)
        let view = item.button
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        stack.insertArrangedSubview(view, at: toChipIndex)
    }

    private func positionIndicator(windowPoint: NSPoint) {
        guard let indicator = dragIndicator else { return }
        let origin = convert(windowPoint, from: nil)
        indicator.frame.origin = NSPoint(
            x: origin.x - dragGrabOffset.x,
            y: origin.y - dragGrabOffset.y
        )
    }

    private func snapshot(_ view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - UI smoke

    var smokeScrollFrame: NSRect { scrollView.frame }

    /// Scrolls to the far end and reports where the last chip rests
    /// relative to the start of the trailing fade (positive = clear of it).
    func smokeScrollToEndClearance() -> CGFloat? {
        layoutSubtreeIfNeeded()
        guard let last = chips.last?.button, smokeIsOverflowing else { return nil }
        let clip = scrollView.contentView
        let maxX = max(0, stack.fittingSize.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: maxX, y: 0))
        scrollView.reflectScrolledClipView(clip)
        layoutSubtreeIfNeeded()
        guard smokeIsOverflowing, abs(clip.bounds.origin.x - maxX) < 0.5 else { return nil }
        let lastMaxX = last.convert(last.bounds, to: self).maxX
        return (scrollView.frame.maxX - Self.edgeFade) - lastMaxX
    }

    func smokeAllChipFrame(in view: NSView?) -> NSRect? {
        guard let button = chips.first(where: { $0.scope == .all })?.button else { return nil }
        return button.convert(button.bounds, to: view)
    }

    /// Every Scope chip (All first), labelled by title.
    func smokeChipFrames(in view: NSView?) -> [(label: String, frame: NSRect)] {
        chips.map { (label: $0.button.chipTitle, frame: $0.button.convert($0.button.bounds, to: view)) }
    }

    func smokeAllTitleMinX(in view: NSView?) -> CGFloat? {
        chips.first(where: { $0.scope == .all })?.button.smokeTitleMinX(in: view)
    }

    func smokeAddButtonFrame(in view: NSView?) -> NSRect {
        addButton.convert(addButton.bounds, to: view)
    }

    var smokeIsOverflowing: Bool { scrollView.layer?.mask != nil }

    func smokeSelectedChipForegroundColor() -> NSColor? {
        guard let button = chips.first(where: { $0.button.isSelectedScope })?.button else { return nil }
        return button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    func smokeSelectedChipFillColor() -> CGColor? {
        chips.first(where: { $0.button.isSelectedScope })?.button.layer?.backgroundColor
    }

    func smokeChipUsesGlass() -> Bool {
        chips.contains { chip in
            chip.button.subviews.contains { $0 is GlassCapsuleView }
        }
    }

    /// "+" is never selected, so its stroke is the idle chip outline.
    func smokeIdleChipBorderColor() -> CGColor? {
        addButton.layer?.borderColor
    }

    var smokeIdleChipBorderWidth: CGFloat {
        addButton.layer?.borderWidth ?? 0
    }
}
