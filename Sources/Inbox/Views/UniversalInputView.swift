import AppKit

/// Floating rounded-rect wrapping Universal Input. No search glyph: the
/// field creates and searches, and a magnifying glass would read as
/// search-only.
final class UniversalInputView: NSView {
    static let chromeHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 12

    let textField = NSTextField()
    private let chrome = GlassCapsuleView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false

        chrome.cornerRadius = Self.cornerRadius
        chrome.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        textField.placeholderString = "Record or search…"
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
        textField.setAccessibilityLabel("Record or search")

        chrome.contentView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: chrome.contentView.leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: chrome.contentView.trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: chrome.contentView.centerYAnchor)
        ])
    }

    /// Clicks on chrome padding land on the field so the caret appears
    /// without a dead zone around the text.
    /// `hitTest` receives a point in the superview, so compare against `frame`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === textField { return textField }
        return frame.contains(point) ? textField : hit
    }
}
