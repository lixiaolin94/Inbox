import AppKit

/// Key cap + action pairs for the current focus state, at the trailing end
/// of a bottom bar (docs/ui.md §5). Display only: it never takes the mouse
/// or first responder, so it sits beside the chips without changing what
/// Universal Input or the list sees.
final class HintBarView: NSView {
    /// `key` is the keyboard glyph as text ("↵", "esc"); the cap draws the
    /// matching SF Symbol when there is one and falls back to the text.
    typealias Hint = (key: String, action: String)

    private let stack = NSStackView()
    private var shown: [Hint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.Spacing.xl
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Hints give way first when the bar is short of room: let the stack
        // clip instead of fighting the chips' required widths.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ hints: [Hint]) {
        guard !hints.elementsEqual(shown, by: { $0.key == $1.key && $0.action == $1.action }) else { return }
        shown = hints
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for hint in hints {
            stack.addArrangedSubview(makeItem(hint))
        }
    }

    var hintTexts: [String] { shown.map { "\($0.key) \($0.action)" } }

    private func makeItem(_ hint: Hint) -> NSView {
        let label = NSTextField(labelWithString: hint.action)
        label.font = Theme.Typography.hint
        label.textColor = Theme.Ink.tertiary
        label.refusesFirstResponder = true
        let item = NSStackView(views: [KeyCapView(key: hint.key), label])
        item.orientation = .horizontal
        item.alignment = .centerY
        item.spacing = Theme.Spacing.xs
        return item
    }
}

/// The key glyph in an 18 pt rounded rect: `Ink.selection` fill,
/// `Ink.outline` stroke, resolved under the effective appearance in
/// `updateLayer`. Glyphs are SF Symbols (text-drawn arrows look like
/// fallback glyphs next to the system font); "esc" stays a word — the ⎋
/// symbol is not widely read.
private final class KeyCapView: NSView {
    private static let height: CGFloat = 18
    private static let symbols: [String: String] = [
        "↵": "return",
        "␣": "space",
        "⌫": "delete.left",
        "↓": "arrow.down",
        "↑": "arrow.up"
    ]
    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Theme.Typography.keyCap.pointSize, weight: .semibold
    )

    private let glyph = CALayer()
    private let symbol: NSImage?
    private let slot: NSSize

    init(key: String) {
        symbol = Self.symbols[key].flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: key)?.withSymbolConfiguration(Self.symbolConfiguration)
        }
        if let symbol {
            slot = NSSize(width: ceil(symbol.size.width), height: ceil(symbol.size.height))
        } else {
            slot = .zero
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        if symbol != nil {
            glyph.contentsGravity = .center
            layer?.addSublayer(glyph)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Self.height),
                widthAnchor.constraint(equalToConstant: max(Self.height, slot.width + Theme.Spacing.sm * 2))
            ])
        } else {
            let label = NSTextField(labelWithString: key)
            label.font = Theme.Typography.keyCap
            label.textColor = Theme.Ink.tertiary
            label.refusesFirstResponder = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Self.height),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.sm),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.sm),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        glyph.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.Chip.resolved(Theme.Ink.selection)
        layer?.borderColor = Theme.Chip.resolved(Theme.Ink.outline)
        if let symbol {
            // Tint is baked under the current appearance; updateLayer runs
            // again on appearance change, so the contents never go stale.
            glyph.contents = symbol.tinted(Theme.Ink.tertiary, centeredIn: slot)
        }
    }
}
