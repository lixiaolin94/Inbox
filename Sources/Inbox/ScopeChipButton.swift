import AppKit

/// One Scope Bar chip. Self-drawn (rounded pill background via CALayer)
/// rather than relying on a stock NSButton bezel, so selection is visually
/// unambiguous regardless of bezel style differences across macOS versions.
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

    var isSelectedScope = false {
        didSet {
            guard oldValue != isSelectedScope else { return }
            applyAppearance()
        }
    }

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        refusesFirstResponder = true
        applyAppearance()
    }

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

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 20, height: 22)
    }

    private func applyAppearance() {
        let color: NSColor = isSelectedScope ? .white : .labelColor
        let weight: NSFont.Weight = isSelectedScope ? .semibold : .regular
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 12, weight: weight)
            ]
        )
        layer?.backgroundColor = isSelectedScope
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }
}
