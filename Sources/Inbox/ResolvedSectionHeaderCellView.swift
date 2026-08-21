import AppKit

/// Lightweight, non-interactive subsection label between Open and Resolved
/// records (PRD §11). Not a GroupID, not collapsible, not in the ↑↓ sequence.
final class ResolvedSectionHeaderCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "Resolved")
    private var leadingConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViews() {
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        leadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            leadingConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    func configure(indented: Bool) {
        leadingConstraint.constant = indented ? 32 : 16
    }
}
