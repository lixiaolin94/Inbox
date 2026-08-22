import AppKit

/// Single source of design tokens (docs/ui.md §2). Views read from here;
/// nothing else defines a chrome size, radius, ink stop or font.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
    }

    enum Radius {
        static let input: CGFloat = 12
        static let row: CGFloat = 10
        /// Filled buttons (utility / Trash action bars).
        static let control: CGFloat = 6
    }

    enum Size {
        static let windowDefault = NSSize(width: 720, height: 480)
        static let windowMinimum = NSSize(width: 480, height: 320)
        static let inputHeight: CGFloat = 48
        static let scopeBarHeight: CGFloat = 36
        static let chipHeight: CGFloat = 26
        /// Bar buttons sit `windowInset` off the bottom edge — the same air
        /// as the sides — with a short run-in above for the list to dissolve
        /// into (ui.md §5).
        static var utilityBarHeight: CGFloat { chipHeight + windowInset + Spacing.md }
        static let chipTitlePadding: CGFloat = 22
        static let chipSpacing: CGFloat = 8
        /// Window edge → outermost chrome: Input capsule, Scope Bar rail and
        /// "+", bar buttons, the gap under them, Trash's bars.
        /// Tune the ring with this one; it does not move the list's rails.
        static let windowInset: CGFloat = 12
        /// Window edge → the list's own rails: selection block edges, text
        /// rail, time column. Independent of `windowInset` on purpose.
        static let contentInset: CGFloat = 12
        static let groupHeaderHeight: CGFloat = 28
        static let disclosureSize: CGFloat = 12
        /// Optical shift for list text (Priority / project names) relative to
        /// the "All" letters. Negative = left. Tweak this, not the cell layouts.
        static let listTextNudge: CGFloat = -2
        /// Extra trailing inset for the group-header chevron so it optically
        /// lines up with time glyphs and the Trash chip. Larger = further left.
        /// Glyph cell of the symbol-only capsule ("+"): this plus
        /// `chipTitlePadding` is the chip width, so the centre everything on
        /// the right rail aligns to never depends on the glyph (symbols are
        /// drawn at natural size, centred on their alignment band).
        static let symbolCellWidth: CGFloat = 16
        /// A symbol-only chip ("+") is `symbolCellWidth + chipTitlePadding`
        /// wide; this puts the group chevron's centre under its centre —
        /// both measured from `windowInset` at the trailing edge.
        static var disclosureNudge: CGFloat { (symbolCellWidth + chipTitlePadding - disclosureSize) / 2 }
        /// Left edge of list text: All's letters plus `listTextNudge`.
        static var textRail: CGFloat { contentInset + chipTitlePadding / 2 + listTextNudge }
        /// Optical shift for the time column relative to the "+" glyph's
        /// right edge. Positive = further left. The glyph edge alone read as
        /// too far right on screen; the value is the user's eye.
        static let timeTextNudge: CGFloat = 4
        /// Right edge of the time column, from the trailing window edge: the
        /// "+" chip's inner padding (the glyph's right edge lands 3 in from
        /// there) plus `timeTextNudge`.
        static var timeRail: CGFloat { contentInset + chipTitlePadding / 2 + timeTextNudge }

        /// Leading constant that puts `view`'s origin on All's *text* edge,
        /// cancelling NSTableView's cell inset.
        static func leadingConstant(for view: NSView) -> CGFloat {
            guard view.bounds.width > 1, let host = view.window?.contentView else { return textRail }
            let x = view.convert(.zero, to: host).x
            return textRail - x
        }

        /// Trailing constraint constant so a subview pinned to `view.trailing`
        /// lands `inset` inside the window.
        static func trailingConstant(for view: NSView, inset: CGFloat = contentInset) -> CGFloat {
            guard view.bounds.width > 1, let host = view.window?.contentView else { return -inset }
            let maxX = view.convert(NSPoint(x: view.bounds.width, y: 0), to: host).x
            return (host.bounds.width - inset) - maxX
        }
    }

    /// Optical relations between rendered *ink* (not frames) that define
    /// the left and right rails (ui.md §3). The UI smoke renders the window
    /// and measures glyph edges against these; change a nudge or a chip
    /// metric and the smoke says whether the eye-level rule still holds.
    enum Optical {
        /// The date's last glyph ends this far left of the chevron's ink
        /// right edge: a vertical stroke next to a diagonal tucks in.
        static let timeInsideChevron: CGFloat = 3
        /// The group chevron's ink centre sits under the "+" glyph's centre.
        static let chevronUnderPlus: CGFloat = 0
        /// List text ink (the Priority glyph) may start this far right of
        /// All's first letter: side bearings of "P" vs "A".
        static let listTextAfterAll: CGFloat = 1
        /// Symbol-only chips: glyph ink centre vs chip centre, both axes.
        static let iconCentred: CGFloat = 0
        static let tolerance: CGFloat = 1
    }

    /// One alpha ladder, no grey values: white on dark appearances, black on
    /// light ones, at the same alpha (ui.md §2.1).
    enum Ink {
        static let primary = at(0.95)
        static let secondary = at(0.60)
        static let tertiary = at(0.40)
        static let outline = at(0.20)
        static let selection = at(0.10)
        static let hover = at(0.05)

        static func at(_ alpha: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                (isDark(appearance) ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
            }
        }

        static func isDark(_ appearance: NSAppearance) -> Bool {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            return match == .darkAqua || match == .vibrantDark
        }
    }

    /// The ink ladder's mirror: white on light appearances, black on dark
    /// ones — what the Input capsule is made of. A "paper" fill lifts a
    /// control off the surface (lighter in light mode, darker in dark mode)
    /// instead of staining it like ink does (ui.md §2.1).
    enum Paper {
        /// Selected Scope chip. 0.45 read as "almost the surface" on
        /// screen; 0.7 is clearly lifted without matching the Input.
        static let raised = at(0.7)
        /// The selected chip's 1pt rim: pure paper (white / black), so the
        /// edge is one step brighter than the fill and reads as a lip.
        static let edge = at(1)

        static func at(_ alpha: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                (Ink.isDark(appearance) ? NSColor.black : NSColor.white).withAlphaComponent(alpha)
            }
        }
    }

    /// Fonts take their *size* from a text style but are built with
    /// `systemFont(ofSize:weight:)`: `preferredFont(forTextStyle:)` carries a
    /// non-zero `leading` that nudges single-line labels by a pixel.
    /// Styles whose size does not match the shipped metric keep the literal
    /// (see ui.md §2.4): input 16 (`.title3` is 15), chip 12 medium
    /// (`.caption1` is 10), group header 12 semibold (`.subheadline` is 11).
    enum Typography {
        static let input = NSFont.systemFont(ofSize: 16)
        static var row: NSFont { NSFont.systemFont(ofSize: Preferences.recordFontSize) }
        static let groupHeader = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let chip = NSFont.systemFont(ofSize: 12, weight: .medium)
        /// Secondary-surface title drawn where a window title would sit.
        static let windowTitle = NSFont.titleBarFont(ofSize: 13)
    }

    enum Chip {
        /// Scope Bar chips are stroked capsules; bar buttons are filled
        /// rounded rects so "this is a button" reads without a bezel
        /// (ui.md §2.2, §5).
        enum Style {
            case capsule
            case filled
            /// Text-only: no fill, no stroke, `Ink.secondary` — a link-like
            /// control such as Trash's Back.
            case plain
        }

        static let outlineColor = Ink.outline
        /// Selected capsule is paper, not ink: it lifts off the surface the
        /// way the Input does, so it reads apart from the selected row's
        /// 10 % ink block.
        static let selectedFill = Paper.raised
        static let selectedEdge = Paper.edge
        /// Filled button at rest sits one stop below the selected row so the
        /// bar never competes with records; selected goes up to `selection`.
        static let buttonFill = Ink.hover
        static let buttonSelectedFill = Ink.selection

        static func paint(_ layer: CALayer, style: Style, selected: Bool, in appearance: NSAppearance) {
            appearance.performAsCurrentDrawingAppearance {
                switch (style, selected) {
                case (.capsule, true):
                    layer.backgroundColor = resolved(selectedFill)
                    layer.borderWidth = 1
                    layer.borderColor = resolved(selectedEdge)
                case (.capsule, false):
                    layer.backgroundColor = NSColor.clear.cgColor
                    layer.borderWidth = 1
                    layer.borderColor = resolved(outlineColor)
                case (.filled, let on):
                    layer.backgroundColor = resolved(on ? buttonSelectedFill : buttonFill)
                    layer.borderWidth = 0
                    layer.borderColor = NSColor.clear.cgColor
                case (.plain, _):
                    layer.backgroundColor = NSColor.clear.cgColor
                    layer.borderWidth = 0
                    layer.borderColor = NSColor.clear.cgColor
                }
            }
        }

        static func resolved(_ color: NSColor) -> CGColor {
            color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
        }
    }
}
