import AppKit

/// Capsule host that uses Liquid Glass on macOS 26+ and a frosted
/// `NSVisualEffectView` fallback on earlier systems.
///
/// Callers size this view; corner radius always tracks `bounds.height / 2`.
/// Put controls inside `contentView` — do not add siblings on top of the
/// glass, which would sit outside the material.
final class GlassCapsuleView: NSView {
    let contentView = NSView()

    var tintColor: NSColor? {
        didSet { applyChrome() }
    }

    private var glass: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        wantsLayer = true
        layer?.masksToBounds = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true

        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.contentView = contentView
            if #available(macOS 27.0, *) {
                view.effectIsInteractive = true
            }
            embed(view)
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .headerView
            view.blendingMode = .withinWindow
            view.state = .followsWindowActiveState
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            view.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: view.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            embed(view)
            glass = view
        }
        applyChrome()
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    /// Glass is decoration. Claim nothing except interactive descendants
    /// actually placed in `contentView` (Universal Input's text field).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit == nil || hit === self || hit === glass || hit === contentView {
            return nil
        }
        return hit
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        applyChrome()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    private func applyChrome() {
        let radius = max(bounds.height, 1) / 2
        if #available(macOS 26.0, *) {
            guard let view = glass as? NSGlassEffectView else { return }
            view.cornerRadius = radius
            view.tintColor = tintColor
        } else if let view = glass as? NSVisualEffectView {
            view.layer?.cornerRadius = radius
            view.layer?.backgroundColor = fallbackFill().cgColor
        }
    }

    private func fallbackFill() -> NSColor {
        var color = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let tintColor {
                color = tintColor.withAlphaComponent(0.35)
            } else {
                color = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
            }
        }
        return color
    }
}
