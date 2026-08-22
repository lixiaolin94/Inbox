import AppKit

/// Scroll-driven luminance mask on a list's scroll view so rows ghost out
/// under the transparent bars overlaying its ends instead of being cut by
/// a line (docs/ui.md §4). The top band is on only once content has
/// scrolled under the top bar; the bottom band whenever content is hidden
/// below. A pure function of scroll state that never touches layout, so it
/// cannot feed back into scrolling (same pattern as `ScopeBarView`).
final class EdgeDissolve: NSObject {
    private let scrollView: NSScrollView
    private let mask = CAGradientLayer()
    private let topBar: CGFloat
    private let bottomBar: CGFloat
    /// How far past each bar's inner edge the fade reaches into the list.
    private static let topOvershoot: CGFloat = 32
    private static let bottomOvershoot: CGFloat = 28

    private(set) var isTopActive = false
    private(set) var isBottomActive = false

    /// `topBar`/`bottomBar` are the overlay bars' heights. Content under a
    /// bar is fully masked — the chips have no backing, so any ghost text
    /// would collide with them — and ghosts in across the overshoot.
    init(scrollView: NSScrollView, topBar: CGFloat, bottomBar: CGFloat) {
        self.scrollView = scrollView
        self.topBar = topBar
        self.bottomBar = bottomBar
        super.init()
        scrollView.wantsLayer = true
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(update),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Rows appearing or growing change what is hidden below without
        // moving the clip view.
        if let document = scrollView.documentView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(update),
                name: NSView.frameDidChangeNotification,
                object: document
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func update() {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let height = scrollView.bounds.height
        let scrolledPastRest = clip.bounds.origin.y + insets.top
        let hiddenBelow = (scrollView.documentView?.frame.height ?? 0) + insets.bottom
            - (clip.bounds.origin.y + clip.bounds.height)
        isTopActive = height > 0 && scrolledPastRest > 0.5
        isBottomActive = height > 0 && hiddenBelow > 0.5

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isTopActive || isBottomActive else {
            scrollView.layer?.mask = nil
            return
        }
        // The scroll view's layer geometry is flipped: unit y 0 is the
        // view's TOP (verified in the pixel snapshots — the first guess
        // masked the wrong end). Stops per end: edge (0) → bar's inner edge
        // (0) → overshoot end (1).
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        let opaque = NSColor.black.cgColor
        let topInner = isTopActive ? topBar / height : 0
        let topOuter = isTopActive ? (topBar + Self.topOvershoot) / height : 0
        let bottomInner = isBottomActive ? 1 - bottomBar / height : 1
        let bottomOuter = isBottomActive ? 1 - (bottomBar + Self.bottomOvershoot) / height : 1
        mask.frame = scrollView.bounds
        mask.colors = [
            isTopActive ? clear : opaque, isTopActive ? clear : opaque, opaque,
            opaque, isBottomActive ? clear : opaque, isBottomActive ? clear : opaque
        ]
        mask.locations = [
            0,
            NSNumber(value: Double(min(topInner, 0.5))),
            NSNumber(value: Double(min(topOuter, 0.5))),
            NSNumber(value: Double(max(bottomOuter, 0.5))),
            NSNumber(value: Double(max(bottomInner, 0.5))),
            1
        ]
        scrollView.layer?.mask = mask
    }
}
