import AppKit

/// All View group header: name on the leading rail, collapse control on
/// the trailing rail. The whole row toggles; Project groups also offer a
/// right-click Rename/Delete menu.
final class GroupHeaderCellView: NSTableCellView {
    private let titleLabel = FlushLabel(labelWithString: "")
    private let disclosureView = NSImageView()
    private var titleLeadingConstraint: NSLayoutConstraint!
    private static let disclosureSize: CGFloat = 12

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
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        disclosureView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        disclosureView.contentTintColor = .tertiaryLabelColor
        disclosureView.imageScaling = .scaleProportionallyDown
        disclosureView.translatesAutoresizingMaskIntoConstraints = true

        addSubview(titleLabel)
        addSubview(disclosureView)

        // The whole row is the control; the chevron is decoration.
        setAccessibilityElement(true)
        disclosureView.setAccessibilityElement(false)

        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: LayoutChrome.contentInset
        )
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),

            titleLeadingConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -(LayoutChrome.contentInset + Self.disclosureSize + 8 + LayoutChrome.disclosureNudge)
            )
        ])
    }

    override func layout() {
        super.layout()
        let leading = LayoutChrome.leadingConstant(for: self)
        if abs(titleLeadingConstraint.constant - leading) > 0.5 {
            titleLeadingConstraint.constant = leading
        }
        let size = Self.disclosureSize
        let trailingPad = -LayoutChrome.trailingConstant(for: self) + LayoutChrome.disclosureNudge
        disclosureView.frame = NSRect(
            x: bounds.width - trailingPad - size,
            y: ((bounds.height - size) / 2).rounded(.toNearestOrAwayFromZero),
            width: size,
            height: size
        )
    }

    func configure(title: String, isCollapsed: Bool, showsDisclosure: Bool = true) {
        titleLabel.stringValue = title
        disclosureView.isHidden = !showsDisclosure
        setAccessibilityRole(showsDisclosure ? .button : .staticText)
        guard showsDisclosure else {
            setAccessibilityLabel(title)
            return
        }
        setAccessibilityLabel("\(title), \(isCollapsed ? "collapsed" : "expanded")")
        let name = isCollapsed ? "chevron.right" : "chevron.down"
        let description = isCollapsed ? "Expand" : "Collapse"
        disclosureView.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?()
    }

    func smokeTitleMinX(in view: NSView?) -> CGFloat {
        titleLabel.convert(titleLabel.bounds, to: view).minX
    }

    func smokeDisclosureMinX(in view: NSView?) -> CGFloat {
        disclosureView.convert(disclosureView.bounds, to: view).minX
    }

    func smokeDisclosureMaxX(in view: NSView?) -> CGFloat {
        disclosureView.convert(disclosureView.bounds, to: view).maxX
    }

    var smokeDisclosureHidden: Bool { disclosureView.isHidden }
}
