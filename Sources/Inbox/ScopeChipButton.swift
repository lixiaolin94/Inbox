import AppKit

/// One Scope Bar chip. Capsule glass (tinted when selected) rather than a
/// stock bezel or a solid accent fill, so selection stays obvious without
/// flattening into a blue lozenge.
///
/// `refusesFirstResponder = true` is the load-bearing bit: clicking a chip
/// must switch Scope without stealing first responder away from Universal
/// Input or a focused Row (PRD "鼠标点击切换 Scope 不得抢走 Universal Input 的焦点").
final class ScopeChipButton: NSButton {
    /// Closure-based instead of target/action so `ScopeBarView` can wire
    /// each chip inline without a trampoline object per chip.
    var onClick: (() -> Void)?
    var isDraggable = false
    var onBeginDrag: ((NSPoint) -> Void)?
    var onDraggedTo: ((NSPoint) -> Void)?
    var onEndDrag: (() -> Void)?
    var onBuildMenu: (() -> NSMenu?)?
    var onDropRecords: (([String]) -> Void)?

    /// Project chips only. All and "+" stay false.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            if isDropTarget {
                registerForDraggedTypes([RecordDragTypes.recordID])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    var isSelectedScope = false {
        didSet {
            guard oldValue != isSelectedScope else { return }
            applyAppearance()
        }
    }

    private var isDropHighlighted = false

    private let capsule = GlassCapsuleView()

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        refusesFirstResponder = true
        capsule.translatesAutoresizingMaskIntoConstraints = true
        capsule.autoresizingMask = [.width, .height]
        addSubview(capsule, positioned: .below, relativeTo: nil)
        applyAppearance()
    }

    override func layout() {
        super.layout()
        capsule.frame = bounds
    }

    /// Keep mouse and drop handling on the button; the glass is decoration.
    /// `hitTest` receives a point in the superview, so compare against `frame`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragging = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            switch next.type {
            case .leftMouseDragged:
                guard isDraggable else { continue }
                let dx = next.locationInWindow.x - start.x
                let dy = next.locationInWindow.y - start.y
                if !dragging && (dx * dx + dy * dy) >= 16 {
                    dragging = true
                    onBeginDrag?(next.locationInWindow)
                }
                if dragging {
                    onDraggedTo?(next.locationInWindow)
                }
            case .leftMouseUp:
                if dragging {
                    onEndDrag?()
                } else {
                    let local = convert(next.locationInWindow, from: nil)
                    if bounds.contains(local) {
                        onClick?()
                    }
                }
                return
            default:
                break
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?()
    }

    // MARK: - Record drop (NSDraggingDestination)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        setDropHighlighted(true)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        let ids = recordIDs(from: sender)
        guard !ids.isEmpty else { return false }
        onDropRecords?(ids)
        return true
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 22, height: 26)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let highlighted = isSelectedScope || isDropHighlighted
        let weight: NSFont.Weight = highlighted ? .semibold : .regular
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: weight)
            ]
        )
        capsule.tintColor = highlighted ? .controlAccentColor : nil
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        guard isDropHighlighted != highlighted else { return }
        isDropHighlighted = highlighted
        applyAppearance()
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget && !recordIDs(from: sender).isEmpty
    }

    private func recordIDs(from sender: NSDraggingInfo) -> [String] {
        guard let items = sender.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { $0.string(forType: RecordDragTypes.recordID) }
    }
}
