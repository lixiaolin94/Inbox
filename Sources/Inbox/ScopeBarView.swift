import AppKit

/// `All | Project 1 | … | +` between Universal Input and the Record List
/// (PRD §5.1, §7.1). A horizontally scrolling row of self-drawn chip buttons
/// — deliberately not NSToolbar or NSSegmentedControl, neither of which fits
/// an open-ended, rebuild-on-the-fly, scrollable Project list well.
final class ScopeBarView: NSView {
    /// Fired when the user clicks a chip (including "All").
    var onSelectScope: ((Scope) -> Void)?
    /// Fired when the user clicks "+".
    var onCreateProject: (() -> Void)?
    /// Fired after a Project chip drag settles on a new order. The array is
    /// the complete Project id list in left-to-right order.
    var onReorderProjects: (([String]) -> Void)?
    /// Right-click menu for a Project chip (Rename / Delete). All and + have none.
    var onBuildProjectMenu: ((String) -> NSMenu?)?
    /// Record ids dropped onto a Project chip, plus that Project's id.
    var onDropRecords: (([String], String?) -> Void)?

    /// Matches Universal Input's side inset so All lines up with the
    /// capsule. Lives on the chip row, not the clip view: overflow still
    /// clips at the window edge, and the first chip's glass is not sheared
    /// 16pt in from that edge.
    static let chipRowInset: CGFloat = 16

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
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

    private func setUp() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Self.chipRowInset,
            bottom: 0,
            right: Self.chipRowInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        clipsToBounds = false

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.clipsToBounds = true
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
    }

    /// Rebuilds the chip row from `scope`/`projects` and scrolls the current
    /// selection into view (PRD §7.1: "当前 Scope 必须自动保持可见"). Called
    /// on load, after a Scope switch, and whenever the Project list changes.
    func update(scope: Scope, projects: [Project]) {
        currentScope = scope
        abortChipDrag()

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        chips.removeAll()

        let allButton = makeChip(title: "All", isSelected: scope == .all) { [weak self] in
            self?.onSelectScope?(.all)
        }
        stack.addArrangedSubview(allButton)
        chips.append((.all, allButton))

        for project in projects {
            let projectScope = Scope.project(id: project.id)
            let projectID = project.id
            let button = makeChip(title: project.name, isSelected: scope == projectScope) { [weak self] in
                self?.onSelectScope?(projectScope)
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
            stack.addArrangedSubview(button)
            chips.append((projectScope, button))
        }

        let addButton = makeChip(title: "+", isSelected: false) { [weak self] in
            self?.onCreateProject?()
        }
        stack.addArrangedSubview(addButton)

        // Force layout now so `scrollSelectionIntoView` reads up-to-date
        // frames instead of the stale (pre-rebuild) arrangement.
        stack.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        guard let selected = chips.first(where: { $0.scope == currentScope })?.button else { return }
        stack.scrollToVisible(selected.frame)
    }

    private func makeChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> ScopeChipButton {
        let button = ScopeChipButton(title: title)
        button.isSelectedScope = isSelected
        button.onClick = action
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

    /// `from`/`to` are indices in the Project-only sequence (All is chips[0]).
    private func moveProjectChip(from: Int, to: Int) {
        let fromChipIndex = from + 1
        let toChipIndex = to + 1
        let item = chips.remove(at: fromChipIndex)
        chips.insert(item, at: toChipIndex)
        let view = item.button
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        stack.insertArrangedSubview(view, at: toChipIndex)
        stack.layoutSubtreeIfNeeded()
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

    func smokeAllChipFrame(in view: NSView?) -> NSRect? {
        guard let button = chips.first(where: { $0.scope == .all })?.button else { return nil }
        return button.convert(button.bounds, to: view)
    }

    func smokeSelectedChipForegroundColor() -> NSColor? {
        guard let button = chips.first(where: { $0.button.isSelectedScope })?.button else { return nil }
        return button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
}
