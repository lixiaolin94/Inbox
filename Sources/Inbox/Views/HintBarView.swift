import AppKit

/// Key cap + action pairs for the current focus state, at the trailing end
/// of a bottom bar (docs/ui.md §5). Display only: it never takes the mouse
/// or first responder, so it sits beside the chips without changing what
/// Universal Input or the list sees.
final class HintBarView: NSView {
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
/// `updateLayer`.
private final class KeyCapView: NSView {
    private let label: NSTextField

    init(key: String) {
        label = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.keyCap
        layer?.borderWidth = 1
        label.font = Theme.Typography.keyCap
        label.textColor = Theme.Ink.tertiary
        label.refusesFirstResponder = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.sm),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.Chip.resolved(Theme.Ink.selection)
        layer?.borderColor = Theme.Chip.resolved(Theme.Ink.outline)
    }
}
