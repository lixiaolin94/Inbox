import Foundation

/// Placement rule for the ⌥Space summon: the window appears on the screen
/// the mouse is on (Raycast behavior) — summoning on screen A while the
/// window rests on screen B must not open it out of view. Pure logic so
/// the multi-screen cases are unit-testable without real displays.
enum SummonPlacement {
    /// `nil` = leave the window where it is: it already sits on the mouse's
    /// screen (manual positioning is respected), or the mouse is on no
    /// screen. Otherwise the window frame centred in the target screen's
    /// visible area, origin rounded to whole points.
    static func frame(
        windowFrame: NSRect,
        mouse: NSPoint,
        screens: [(frame: NSRect, visible: NSRect)]
    ) -> NSRect? {
        guard let target = screens.first(where: { $0.frame.contains(mouse) }) else { return nil }
        let centre = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        if target.frame.contains(centre) { return nil }
        var frame = windowFrame
        frame.origin = NSPoint(
            x: (target.visible.midX - frame.width / 2).rounded(),
            y: (target.visible.midY - frame.height / 2).rounded()
        )
        return frame
    }
}
