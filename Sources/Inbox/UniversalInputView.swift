import AppKit

/// Floating capsule wrapping Universal Input: search glyph + the same
/// single-line `NSTextField` the rest of the app already talks to.
final class UniversalInputView: NSView {
    static let capsuleHeight: CGFloat = 36

    let textField = NSTextField()
    private let capsule = GlassCapsuleView()
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        textField.placeholderString = "Capture or search…"
        textField.font = .systemFont(ofSize: 16)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        if let cell = textField.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.isScrollable = true
            cell.lineBreakMode = .byClipping
        }
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityLabel("Capture or search")

        capsule.contentView.addSubview(iconView)
        capsule.contentView.addSubview(textField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor)
        ])
    }

    /// Clicks on the glyph or capsule padding land on the field so the
    /// caret appears without a dead zone around the text.
    /// `hitTest` receives a point in the superview, so compare against `frame`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === textField { return textField }
        return frame.contains(point) ? textField : hit
    }
}
