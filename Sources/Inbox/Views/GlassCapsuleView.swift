import AppKit

/// Rounded glass host that uses Liquid Glass on macOS 26+ and a frosted
/// `NSVisualEffectView` fallback on earlier systems.
///
/// Callers size this view. Pass `cornerRadius` for a rounded rect; `nil`
/// (the default) is a capsule (`bounds.height / 2`).
/// Put controls inside `contentView` — do not add siblings on top of the
/// glass, which would sit outside the material.
///
/// This view never clips. `NSGlassEffectView` draws a drop shadow outside
/// its bounds on macOS 26; clipping ancestors shear that shadow into a
/// hard rectangle.
final class GlassCapsuleView: NSView {
    let contentView = NSView()

    var tintColor: NSColor? {
        didSet { applyChrome() }
    }

    /// `nil` means a capsule. Set to a point value for a rounded rect.
    var cornerRadius: CGFloat? {
        didSet { applyChrome() }
    }

    /// 实验（未提交）：clear 玻璃（macOS 26+ 生效；fallback 不变）。
    var prefersClearGlass = false {
        didSet {
            guard #available(macOS 26.0, *), let view = glass as? NSGlassEffectView else { return }
            view.style = prefersClearGlass ? .clear : .regular
        }
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
        clipsToBounds = false
        layer?.masksToBounds = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true

        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.clipsToBounds = false
            view.contentView = contentView
            // macOS 27 新增属性；用 KVC 设置以便在 macOS 26 SDK 上也能编译。
            if #available(macOS 27.0, *) {
                view.setValue(true, forKey: "effectIsInteractive")
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

    private func resolvedCornerRadius() -> CGFloat {
        cornerRadius ?? max(bounds.height, 1) / 2
    }

    private func applyChrome() {
        let radius = resolvedCornerRadius()
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
