import AppKit

/// Chip button in two styles (`Theme.Chip.Style`): the Scope Bar capsule —
/// 1pt stroke when idle, ink-selection fill when selected — and the filled
/// rounded rect used by the utility / Trash action bars. Font weight is
/// constant so selecting a chip does not change its width.
///
/// `refusesFirstResponder = true` is the load-bearing bit: clicking a chip
/// must switch Scope without stealing first responder away from Universal
/// Input or a focused Row (PRD "鼠标点击切换 Scope 不得抢走 Universal Input 的焦点").
final class ScopeChipButton: NSButton {
    var onClick: (() -> Void)?
    var isDraggable = false
    var onBeginDrag: ((NSPoint) -> Void)?
    var onDraggedTo: ((NSPoint) -> Void)?
    var onEndDrag: (() -> Void)?
    var onBuildMenu: (() -> NSMenu?)?
    var onDropRecords: (([String]) -> Void)?
    /// "+" uses a square capsule so it reads as an icon button.
    var prefersSquare = false
    var style: Theme.Chip.Style = .capsule {
        didSet {
            guard style != oldValue else { return }
            needsLayout = true
            applyAppearance()
        }
    }
    /// Leading SF Symbol before the title. Always drawn in the outlined idle
    /// style; state is conveyed by swapping the symbol, not by filling.
    var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            applyAppearance()
            invalidateIntrinsicContentSize()
        }
    }

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
            setAccessibilitySelected(isSelectedScope)
            applyAppearance()
        }
    }

    private var isDropHighlighted = false
    /// `NSButton.title` mirrors `attributedTitle.string`, which would include
    /// the symbol attachment after the first `applyAppearance` — keep the
    /// plain text ourselves.
    private var baseTitle = ""

    /// Plain chip text (use instead of `title`, which NSButton mirrors from
    /// the composed attributed title).
    var chipTitle: String {
        get { baseTitle }
        set {
            guard newValue != baseTitle else { return }
            baseTitle = newValue
            applyAppearance()
        }
    }

    private static var symbolSlot: NSSize { Theme.Size.symbolSlot }

    /// Tinted glyphs keyed by symbol | enabled state | appearance name: the
    /// tint is baked under the appearance current at draw time, so a new
    /// appearance is a new key rather than a stale image. Bounded by a
    /// handful of symbols x 2 states x 2-3 appearances — no eviction needed.
    private static var tintedSymbols: [String: NSImage] = [:]

    private static func tintedSymbol(_ name: String, ink: NSColor, inkKey: String, in appearance: NSAppearance) -> NSImage? {
        let key = "\(name)|\(inkKey)|\(appearance.name.rawValue)"
        if let cached = tintedSymbols[key] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) else { return nil }
        let tinted = symbol.tinted(ink, centeredIn: symbolSlot)
        tintedSymbols[key] = tinted
        return tinted
    }

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        baseTitle = title
        let chipCell = ScopeChipButtonCell()
        chipCell.isBordered = false
        chipCell.highlightsBy = []
        chipCell.showsStateBy = []
        chipCell.alignment = .left
        chipCell.title = title
        chipCell.font = Theme.Typography.chip
        cell = chipCell
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        refusesFirstResponder = true
        applyAppearance()
    }

    func smokeTitleMinX(in view: NSView?) -> CGFloat {
        let rect = (cell as? NSButtonCell)?.titleRect(forBounds: bounds) ?? bounds
        return convert(rect, to: view).minX
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            applyAppearance()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
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
        let width = ceil(attributedTitle.size().width)
        var total = width + Theme.Size.chipTitlePadding
        if prefersSquare {
            total = max(total, Theme.Size.chipHeight)
        }
        return NSSize(width: total, height: Theme.Size.chipHeight)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = style == .capsule ? max(bounds.height, 1) / 2 : Theme.Radius.control
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        // Symbol chips convey state by swapping the glyph (eye / eye.slash);
        // filled buttons can carry both, so the fill follows the state there.
        let highlighted = (symbolName == nil || style == .filled) && (isSelectedScope || isDropHighlighted)
        let (color, inkKey): (NSColor, String) = switch (isEnabled, style) {
        case (false, _): (Theme.Ink.tertiary, "tertiary")
        case (true, .plain): (Theme.Ink.secondary, "secondary")
        case (true, _): (Theme.Ink.primary, "primary")
        }
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: Theme.Typography.chip]
        let composed = NSMutableAttributedString()
        if let symbolName,
           let symbol = Self.tintedSymbol(symbolName, ink: color, inkKey: inkKey, in: effectiveAppearance) {
            // Inline attachment keeps the glyph on the title's text rail
            // instead of NSButton's separate image slot.
            let attachment = NSTextAttachment()
            let size = Self.symbolSlot
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: (Theme.Typography.chip.capHeight - size.height) / 2, width: size.width, height: size.height)
            composed.append(NSAttributedString(attachment: attachment))
            if !baseTitle.isEmpty {
                composed.append(NSAttributedString(string: " ", attributes: attributes))
            }
        }
        composed.append(NSAttributedString(string: baseTitle, attributes: attributes))
        attributedTitle = composed
        invalidateIntrinsicContentSize()
        alphaValue = isEnabled ? 1 : 0.45
        if let layer {
            Theme.Chip.paint(layer, style: style, selected: highlighted, in: effectiveAppearance)
        }
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

/// Left-aligned title so "All" shares a text rail with list Priority /
/// project names. "+" stays centered in its square chip.
private final class ScopeChipButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let size = attributedTitle.size()
        let pad = Theme.Size.chipTitlePadding / 2
        let y = ((rect.height - size.height) / 2).rounded(.toNearestOrAwayFromZero)
        if (controlView as? ScopeChipButton)?.prefersSquare == true {
            let x = ((rect.width - size.width) / 2).rounded(.toNearestOrAwayFromZero)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        return NSRect(
            x: pad,
            y: y,
            width: min(size.width, max(0, rect.width - pad * 2)),
            height: size.height
        )
    }
}

extension NSImage {
    /// Bakes `color` into the glyph, centred in `slot` (scaled down if
    /// larger). Shared by chips and key caps; re-bake on appearance change.
    func tinted(_ color: NSColor, centeredIn slot: NSSize) -> NSImage {
        let glyph = size
        let result = NSImage(size: slot, flipped: false) { rect in
            let scale = min(1, slot.width / max(glyph.width, 1), slot.height / max(glyph.height, 1))
            let drawn = NSSize(width: glyph.width * scale, height: glyph.height * scale)
            let origin = NSPoint(x: ((rect.width - drawn.width) / 2).rounded(), y: ((rect.height - drawn.height) / 2).rounded())
            self.draw(in: NSRect(origin: origin, size: drawn))
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
