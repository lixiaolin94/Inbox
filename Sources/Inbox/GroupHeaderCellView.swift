import AppKit

/// All View group header: disclosure + name. Click toggles collapse; Project
/// groups also offer a right-click Rename/Delete menu. Inbox has no menu.
///
/// Hits are claimed by the cell itself so the triangle and title don't
/// swallow clicks into their own NSTextField.
final class GroupHeaderCellView: NSTableCellView {
    private let disclosureLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    var onToggle: (() -> Void)?
    var onBuildMenu: (() -> NSMenu?)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViews() {
        disclosureLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        disclosureLabel.textColor = .secondaryLabelColor
        disclosureLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureLabel)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            disclosureLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            disclosureLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureLabel.widthAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureLabel.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    func configure(title: String, isCollapsed: Bool) {
        disclosureLabel.stringValue = isCollapsed ? "▶" : "▼"
        titleLabel.stringValue = title
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?()
    }
}
