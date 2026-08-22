import AppKit

/// `--snapshot-dir`: renders the surfaces to PNG for pixel review.
extension UISmokeRunner {
    /// Renders the real window content to `<dir>/<surface>-<state>-<appearance>-<width>.png`
    /// for light/dark × 480/720/1100 pt × main / Show Resolved / Trash, plus
    /// Row Focus and Inline Edit at 720 pt light, so a reviewer who cannot
    /// look at the screen can look at PNGs. `manifest.txt` lists each file
    /// with its pixel size. Runs last and puts everything back (appearance,
    /// frame, Show Resolved, main surface, Input focused).
    ///
    /// `cacheDisplay` covers `contentView` only: the titlebar (traffic
    /// lights) is a sibling view and never appears, and the `behindWindow`
    /// blur is composited by the window server, so the sidebar material
    /// renders without whatever sits behind the window.
    static func stepSnapshots(
        window: NSWindow,
        controller: MainViewController,
        store: RecordStore,
        directory: String
    ) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let longID = try seedSnapshotData(controller: controller, store: store)
        // Projects exist now, so the All view has group headers to measure.
        try waitUntil(showing: "group header rendered for the chevron check") {
            controller.smokeFirstGroupHeaderDisclosureMinX != nil
        }
        if let disclosureX = controller.smokeFirstGroupHeaderDisclosureMinX {
            try assertClose(
                disclosureX + Theme.Size.disclosureSize / 2,
                controller.smokeAddButtonFrame.midX,
                "group chevron centres under the Scope Bar's + chip",
                tolerance: 1
            )
        }
        let originalFrame = window.frame

        func render(_ name: String) throws {
            try renderSnapshot(name, window: window, controller: controller, directory: directory, wrapRecordID: longID)
        }

        func eachVariant(_ body: (String) throws -> Void) throws {
            for (appearance, label) in [(NSAppearance.Name.aqua, "aqua"), (.darkAqua, "darkAqua")] {
                window.appearance = NSAppearance(named: appearance)
                for width: CGFloat in [480, 720, 1100] {
                    setSnapshotFrame(window: window, width: width)
                    try body("\(label)-\(Int(width))")
                }
            }
        }

        // With Project chips on the bar and at every width, not just launch.
        try eachVariant {
            try stepPixelAlignment(window: window, controller: controller)
            try render("main-default-\($0)")
        }

        let openCount = controller.smokeVisibleRecords.count
        controller.smokeClickResolved()
        try waitUntil(showing: "resolved records visible for snapshots") {
            controller.smokeVisibleRecords.count > openCount
        }
        try eachVariant { try render("main-resolved-\($0)") }
        // Rows ghosting under both bars: ↓ to the last row of the (longer)
        // resolved list so the top band is on and the list sits at the end.
        window.appearance = NSAppearance(named: .aqua)
        setSnapshotFrame(window: window, width: 720)
        controller.focusInputAtEnd()
        let resolvedCount = controller.smokeVisibleRecords.count
        for _ in 0..<resolvedCount {
            try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        }
        try waitUntil(showing: "last resolved row selected for the scrolled snapshot") {
            controller.smokeSelectedRecord?.id == controller.smokeVisibleRecords.last?.id
        }
        controller.smokeFlashScrollers()
        pump()
        pump()
        try render("main-scrolled-aqua-720")
        controller.focusInputAtEnd()
        controller.smokeClickResolved()
        try waitUntil(showing: "resolved records hidden again") {
            controller.smokeVisibleRecords.count == openCount
        }

        // Trash rows are laid out by the same cell and gap as the main list:
        // a single-line row there is exactly as tall as one here.
        let shortest = controller.smokeVisibleRecords.min { $0.content.count < $1.content.count }
        let mainRowHeight = shortest.flatMap { controller.smokeRowHeight(forRecordID: $0.id) }
        controller.smokeOpenTrash()
        try waitUntil(showing: "Trash surface listing the trashed records") {
            controller.smokeIsShowingTrash && controller.smokeTrashTableIsFirstResponder
                && ((window.firstResponder as? NSTableView)?.numberOfRows ?? 0) >= 2
        }
        guard let mainRowHeight, let trashRowHeight = controller.smokeTrashRowHeight else {
            throw SmokeFailure("row heights should be measurable on both surfaces")
        }
        try assertClose(trashRowHeight, mainRowHeight, "trash row height matches a single-line main row")
        try eachVariant {
            // The width change re-measures rows; the selection must survive it.
            if (window.firstResponder as? NSTableView)?.selectedRow ?? -1 < 0 {
                throw SmokeFailure("Trash selection lost after resizing to \($0)")
            }
            try render("trash-default-\($0)")
        }
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "main surface back after the Trash snapshots") {
            !controller.smokeIsShowingTrash && controller.smokeIsInputFirstResponder()
        }

        window.appearance = NSAppearance(named: .aqua)
        setSnapshotFrame(window: window, width: 720)
        // Leaving Trash re-runs the search asynchronously; ↓ must not race
        // its completion (the stale list is non-empty, so wait on the
        // search itself — its reload would otherwise clear the selection).
        try waitUntil(showing: "search settled after leaving Trash") {
            controller.smokeSearchSettled && !controller.smokeVisibleRecords.isEmpty
        }
        controller.focusInputAtEnd()
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "first record selected for the Row Focus snapshot") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord != nil
        }
        // Row Focus survives a width change (rows are re-measured without
        // a full reload — see RecordTableView.scheduleHeightNote).
        let focusedBeforeResize = controller.smokeSelectedRecord?.id
        setSnapshotFrame(window: window, width: 1100)
        try assertEqual(controller.smokeSelectedRecord?.id, focusedBeforeResize, "Row Focus kept across a window resize")
        setSnapshotFrame(window: window, width: 720)
        try assertEqual(controller.smokeSelectedRecord?.id, focusedBeforeResize, "Row Focus kept after resizing back")
        try render("main-rowfocus-aqua-720")
        // Creation timestamps can tie at millisecond resolution, so the
        // wrapped record is not guaranteed to be the first row: walk to it.
        var hops = 0
        while controller.smokeSelectedRecord?.id != longID, hops < 12 {
            try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
            hops += 1
        }
        try assertEqual(controller.smokeSelectedRecord?.id, longID, "↓ reaches the wrapped record")
        try sendReturn(window: window)
        try waitUntil(showing: "Inline Edit on the wrapped record") { controller.smokeIsEditingRecord(id: longID) }
        try render("main-inlineedit-aqua-720")
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "Inline Edit ended after the snapshot") { !controller.smokeIsEditingRecord(id: longID) }

        let manifestPath = (directory as NSString).appendingPathComponent("manifest.txt")
        try (snapshotManifest.joined(separator: "\n") + "\n").write(toFile: manifestPath, atomically: true, encoding: .utf8)

        window.appearance = nil
        window.setFrame(originalFrame, display: true)
        window.layoutIfNeeded()
        pump()
        try assertContentSize(of: window, equals: Theme.Size.windowDefault, "content size after snapshots")
        try assertEqual(Preferences.showResolved, false, "Show Resolved off after snapshots")
        try assertEqual(controller.smokeIsShowingTrash, false, "main surface after snapshots")
        controller.focusInputAtEnd()
        try waitUntil(showing: "Universal Input focused after snapshots") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// Every PNG rendered this run, `name.png WxH`, written out by `stepSnapshots`.
    static var snapshotManifest: [String] = []

    /// Renders the window's content view to `<directory>/<name>.png`.
    /// `wrapRecordID` also logs that row's wrap metrics for the pixel review.
    static func renderSnapshot(
        _ name: String,
        window: NSWindow,
        controller: MainViewController,
        directory: String,
        wrapRecordID: String? = nil
    ) throws {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        pump()
        pump()
        if let wrapRecordID {
            if let widths = controller.smokeFieldWidths(forRecordID: wrapRecordID) {
                try assertClose(widths.live, widths.assumed, "\(name): content field width matches the height measurement's width")
            }
            writeLine("WRAP \(name): \(controller.smokeWrapMetrics(forRecordID: wrapRecordID) ?? "-")")
            writeLine("DISSOLVE \(name): \(controller.smokeDissolveDebug)")
        }
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SmokeFailure("\(name): no bitmap for the content view")
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SmokeFailure("\(name): PNG encoding failed")
        }
        let path = (directory as NSString).appendingPathComponent("\(name).png")
        try png.write(to: URL(fileURLWithPath: path))
        snapshotManifest.append("\(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
        writeLine("SNAPSHOT \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// Centres a `width` × 480 frame on the screen so 1100 pt stays visible.
    static func setSnapshotFrame(window: NSWindow, width: CGFloat) {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var frame = window.frame
        frame.size = NSSize(width: width, height: 480)
        frame.origin = NSPoint(x: screen.midX - width / 2, y: screen.midY - frame.height / 2)
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
        window.layoutIfNeeded()
        pump()
    }

    /// Fills the smoke DB so every surface has something to show: Inbox
    /// plus two Projects, one Record long enough to wrap to 3+ lines at
    /// 720 pt, a P0 Record, the resolved Records the earlier steps left
    /// behind, and a second trashed Record. Returns the wrapped Record's id.
    static func seedSnapshotData(controller: MainViewController, store: RecordStore) throws -> String {
        func createProject(_ name: String) throws -> Project {
            var result: Result<Project, Error>?
            store.projects.createProject(name: name) { result = $0 }
            try waitUntil(showing: "project '\(name)' created") { result != nil }
            return try result!.get()
        }
        let openBefore = controller.smokeVisibleRecords.count
        let design = try createProject("Design")
        let ops = try createProject("Ops")
        _ = try createRecordSync(store: store, content: "Review the onboarding mockups with Mei", projectID: design.id)
        _ = try createRecordSync(store: store, content: "Export the icon set at 1x and 2x", projectID: design.id)
        let keys = try createRecordSync(store: store, content: "Rotate the CloudKit production keys", projectID: ops.id)
        _ = try createRecordSync(store: store, content: "Back up the SQLite snapshot before the migration", projectID: ops.id)
        _ = try createRecordSync(store: store, content: "Renew the domain before Friday")
        let long = try createRecordSync(store: store, content: snapshotLongContent)
        let discarded = try createRecordSync(store: store, content: "Old draft to discard")
        try applySync("P0 priority set") { store.updatePriority(id: keys.id, priority: Priority.p0.rawValue, completion: $0) }
        try applySync("second record trashed") { store.moveToTrash(id: discarded.id, completion: $0) }

        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "snapshot projects and records visible") {
            controller.smokeVisibleRecords.count == openBefore + 6
        }
        return long.id
    }

    /// ~220 characters of mixed Chinese and English: wraps to 3+ lines at 720 pt.
    static let snapshotLongContent =
        "把同步冲突处理方案再过一遍：schema v4 加 conflict_of 字段并随 CloudKit 同步，列表里的冲突行在时间列位置显示弱化的 Conflict 标签，"
        + "Utility 栏出现 N conflicts chip，右键菜单提供 Keep This / Keep Other / Keep Both 三个动作；Keep This 把对方移入 Trash，可恢复且无损，"
        + "Keep Both 只清空标记，不新增任何 surface。Review with the team on Thursday and write the numbers into HISTORY."
}
