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
    /// Symbol-only `chipHeight` × `chipHeight` button (utility bar): the
    /// glyph is centred, no title.
    var iconOnly = false {
        didSet {
            guard iconOnly != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
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
    /// 实验（未提交）：`.grouped` 的 hover 圆底。
    private var isHovered = false
    private var hoverArea: NSTrackingArea?
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

    /// Symbol drawn at the chip font's point size, ink baked, **natural
    /// size with its `alignmentRect` intact** — never scaled into a slot:
    /// SF Symbols share one alignment band per point size (8.5pt at 12),
    /// so centring that band is what keeps eye / clock / trash the same
    /// visual size and on one line. Keyed by symbol | ink |
    /// appearance; bounded by a handful of symbols × 3 inks × 2-3
    /// appearances — no eviction needed.
    private static var tintedSymbols: [String: NSImage] = [:]

    private static func tintedSymbol(_ name: String, ink: NSColor, inkKey: String, in appearance: NSAppearance) -> NSImage? {
        let key = "\(name)|\(inkKey)|\(appearance.name.rawValue)"
        if let cached = tintedSymbols[key] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Theme.Typography.chip.pointSize, weight: .medium)) else { return nil }
        let tinted = symbol.tinted(ink)
        tintedSymbols[key] = tinted
        return tinted
    }

    /// The symbol as currently tinted; the cell draws it directly for
    /// symbol-only chips.
    fileprivate private(set) var currentSymbol: NSImage?

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
        smokeTitleFrame(in: view).minX
    }

    func smokeTitleFrame(in view: NSView?) -> NSRect {
        let rect = (cell as? NSButtonCell)?.titleRect(forBounds: bounds) ?? bounds
        return convert(rect, to: view)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if style == .grouped { applyAppearance() }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if style == .grouped { applyAppearance() }
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
        if iconOnly {
            return NSSize(width: Theme.Size.chipHeight, height: Theme.Size.chipHeight)
        }
        if baseTitle.isEmpty, currentSymbol != nil {
            // Symbol-only capsule ("+"): a fixed glyph cell, so the chip's
            // width — and everything aligned to its centre — never depends
            // on which glyph is in it.
            return NSSize(width: Theme.Size.symbolCellWidth + Theme.Size.chipTitlePadding, height: Theme.Size.chipHeight)
        }
        let width = ceil(attributedTitle.size().width)
        var total = width + Theme.Size.chipTitlePadding
        if prefersSquare {
            total = max(total, Theme.Size.chipHeight)
        }
        return NSSize(width: total, height: Theme.Size.chipHeight)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = (style == .capsule || style == .grouped) ? max(bounds.height, 1) / 2 : Theme.Radius.control
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        // Symbol chips convey state by swapping the glyph (eye / eye.slash);
        // filled buttons can carry both, so the fill follows the state there.
        // `.grouped` adds hover: no ground at rest, a round one under the cursor.
        let engaged = isSelectedScope || isDropHighlighted
        let highlighted = style == .grouped
            ? engaged || isHovered
            : (symbolName == nil || style == .filled) && engaged
        let (color, inkKey): (NSColor, String) = switch (isEnabled, style) {
        case (false, _): (Theme.Ink.tertiary, "tertiary")
        case (true, .plain): (Theme.Ink.secondary, "secondary")
        case (true, _): (Theme.Ink.primary, "primary")
        }
        let font = Theme.Typography.chip
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: font]
        currentSymbol = symbolName.flatMap { Self.tintedSymbol($0, ink: color, inkKey: inkKey, in: effectiveAppearance) }
        let composed = NSMutableAttributedString()
        if let symbol = currentSymbol, !baseTitle.isEmpty {
            // Inline attachment keeps the glyph on the title's text rail.
            // Its alignment band is centred on the cap height, which is
            // how SF Symbols are designed to sit next to text.
            let attachment = NSTextAttachment()
            attachment.image = symbol
            let band = symbol.alignmentRect
            attachment.bounds = NSRect(
                x: 0, y: font.capHeight / 2 - band.midY,
                width: symbol.size.width, height: symbol.size.height
            )
            composed.append(NSAttributedString(attachment: attachment))
            composed.append(NSAttributedString(string: " ", attributes: attributes))
        }
        // Symbol-only chips keep an empty title: the cell draws the glyph
        // itself, centred on device pixels (see `ScopeChipButtonCell`).
        composed.append(NSAttributedString(string: baseTitle, attributes: attributes))
        attributedTitle = composed
        invalidateIntrinsicContentSize()
        needsDisplay = true
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
/// project names; text is centred on its cap height, on device pixels.
/// Symbol-only chips ("+", icon buttons) draw the glyph here with its
/// alignment band centred in the chip — not through the attributed
/// title, whose line metrics put glyphs ~1pt low (measured).
private final class ScopeChipButtonCell: NSButtonCell {
    private func pixelRound(_ v: CGFloat, in view: NSView?) -> CGFloat {
        let scale = view?.window?.backingScaleFactor ?? 2
        return (v * scale).rounded() / scale
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let size = attributedTitle.size()
        let pad = Theme.Size.chipTitlePadding / 2
        let font = Theme.Typography.chip
        // Cap centre on the chip's centre line (flipped coordinates).
        let y = pixelRound(rect.midY - font.ascender + font.capHeight / 2, in: controlView)
        if let chip = controlView as? ScopeChipButton, chip.prefersSquare || chip.iconOnly {
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

    /// NSButtonCell skips `drawTitle` for an empty title, so symbol-only
    /// chips draw their glyph here, after the (empty) interior.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
        guard let chip = controlView as? ScopeChipButton, chip.chipTitle.isEmpty, let symbol = chip.currentSymbol else { return }
        let bounds = controlView.bounds
        let band = symbol.alignmentRect
        // Flipped view: the image's bottom is at the rect's maxY; the band
        // is measured from the image's bottom.
        let origin = NSPoint(
            x: pixelRound(bounds.midX - band.midX, in: controlView),
            y: pixelRound(bounds.midY + band.midY - symbol.size.height, in: controlView)
        )
        let rect = NSRect(origin: origin, size: symbol.size)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private extension NSImage {
    /// Bakes `color` into the glyph at natural size, keeping the symbol's
    /// `alignmentRect` so callers can centre its band. Re-bake on
    /// appearance change.
    func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.alignmentRect = alignmentRect
        result.isTemplate = false
        return result
    }
}
