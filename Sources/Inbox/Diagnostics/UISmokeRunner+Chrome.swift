import AppKit

/// Chrome steps: window geometry, Scope Bar, pixel alignment, overlay bars,
/// the optical rails and the utility bar.
extension UISmokeRunner {
    /// Window opens at 720×480, can grow, and cannot shrink below minSize.
    static func stepWindowGeometry(window: NSWindow, controller: MainViewController) throws {
        try assertContentSize(
            of: window,
            equals: Theme.Size.windowDefault,
            "initial window content size"
        )
        try assertEqual(window.titleVisibility, .hidden, "titleVisibility hidden")
        try assertEqual(window.isOpaque, false, "window is translucent")
        guard let effect = window.contentView as? NSVisualEffectView else {
            throw SmokeFailure(
                "content view should be NSVisualEffectView, got \(String(describing: type(of: window.contentView)))"
            )
        }
        try assertEqual(effect.material, NSVisualEffectView.Material.sidebar, "sidebar material")
        try assertEqual(effect.blendingMode, NSVisualEffectView.BlendingMode.behindWindow, "blur samples behind the window")
        if !window.styleMask.contains(.fullSizeContentView) {
            throw SmokeFailure("fullSizeContentView is required so the titlebar shows the window material")
        }
        let fills = TitlebarBackdrop.visibleSystemFills(in: window)
        if !fills.isEmpty {
            throw SmokeFailure("titlebar still paints a system material over the sidebar blur: \(fills)")
        }
        try assertEqual(
            controller.smokeOfflineNoticeVisible,
            false,
            "offline notice hidden when sync engine is off"
        )

        let originalFrame = window.frame

        var wide = originalFrame
        wide.size.width = 900
        window.setFrame(wide, display: true)
        window.layoutIfNeeded()
        pump()
        try assertClose(window.frame.width, 900, "programmatic widen to 900")

        var narrow = window.frame
        narrow.size.width = 400
        window.setFrame(narrow, display: true)
        window.layoutIfNeeded()
        pump()
        if window.frame.width < Theme.Size.windowMinimum.width {
            throw SmokeFailure(
                "minSize should clamp width >= \(Theme.Size.windowMinimum.width), got \(window.frame.width)"
            )
        }

        window.setFrame(originalFrame, display: true)
        window.layoutIfNeeded()
        pump()
        try assertContentSize(
            of: window,
            equals: Theme.Size.windowDefault,
            "content size after restoring original frame"
        )
    }

    /// Floating rounded-rect Input is inset from the window edges and sits
    /// close to the titlebar; Scope Bar chips are plain buttons, not glass.
    /// Standalone bar with more Projects than fit: the last chip must be
    /// able to scroll fully clear of the trailing fade.
    static func stepScopeBarOverflow() throws {
        let bar = ScopeBarView(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        let projects = (0..<12).map {
            Project(id: "smoke-p\($0)", name: "Project \($0)", manualOrder: Int64($0), createdAt: 0, updatedAt: 0)
        }
        bar.update(scope: .all, projects: projects)
        guard let clearance = bar.smokeScrollToEndClearance() else {
            throw SmokeFailure("scope bar with 12 projects in 360pt should overflow")
        }
        if clearance < -0.5 {
            throw SmokeFailure("last scope chip stops \(-clearance)pt inside the trailing fade")
        }
    }

    static func stepChromeGeometry(window: NSWindow, controller: MainViewController) throws {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let input = controller.smokeInputFrame
        try assertClose(input.height, Theme.Size.inputHeight, "input chrome height")
        try assertClose(input.minX, Theme.Size.windowInset, "input floats windowInset from the leading edge")
        if abs(input.width - (controller.view.bounds.width - input.minX * 2)) > 2 {
            throw SmokeFailure("input should keep matching side insets, frame=\(input) view=\(controller.view.bounds)")
        }
        if controller.smokeInputPlaceholder != "Type a record, Enter to save" {
            throw SmokeFailure(
                "input placeholder should be 'Type a record, Enter to save', got '\(controller.smokeInputPlaceholder)'"
            )
        }
        try waitUntil(showing: "titlebar safe area is applied") {
            controller.view.safeAreaInsets.top >= 20
        }
        let topGap = controller.view.bounds.height - input.maxY - controller.view.safeAreaInsets.top
        if topGap < 4 || topGap > 16 {
            throw SmokeFailure(
                "input should sit just below the titlebar, gap=\(topGap) safeArea=\(controller.view.safeAreaInsets.top)"
            )
        }
        try assertClose(controller.smokeScopeBarHeight, 36, "scope bar height")
        try waitUntil(showing: "scope bar All chip exists") {
            controller.smokeAllChipFrameInWindow != nil
        }
        try assertHit(
            ScopeChipButton.self,
            in: window,
            at: midpoint(controller.smokeAllChipFrameInWindow, "All chip"),
            "All chip"
        )
        try assertClose(controller.smokeScopeBarFrame.minX, 0, "scope bar leading at the window edge")
        try assertClose(
            controller.smokeScopeBarFrame.width,
            controller.view.bounds.width,
            "scope bar spans the window"
        )
        try assertClose(
            controller.smokeScopeBarScrollFrame.minX,
            0,
            "scope bar clips at the window edge, not an inner inset"
        )
        guard let allChip = controller.smokeAllChipFrame else {
            throw SmokeFailure("All chip should exist after launch")
        }
        try assertClose(allChip.minX, input.minX, "All chip aligns with the input")
        let add = controller.smokeAddButtonFrame
        if add.width < 20 || add.height < 20 {
            throw SmokeFailure("scope add button should exist, frame=\(add)")
        }
        if add.minX <= allChip.minX {
            throw SmokeFailure("scope add button should sit after All, add=\(add) all=\(allChip)")
        }
        if !controller.smokeTrashAllowsMultipleSelection {
            throw SmokeFailure("Trash should allow multi-select")
        }
        if controller.smokeScopeChipUsesGlass {
            throw SmokeFailure("scope chips should be plain buttons, not glass")
        }
        try assertClose(controller.smokeIdleChipBorderWidth, 1, "idle chip stroke width")
        guard let idleBorder = controller.smokeIdleChipBorderColor else {
            throw SmokeFailure("idle chip should have a stroke color")
        }
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
        var strokeConverted = false
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let borderRGB = NSColor(cgColor: idleBorder)?.usingColorSpace(.deviceRGB),
                  let strokeRGB = Theme.Chip.outlineColor.usingColorSpace(.deviceRGB) else { return }
            borderRGB.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            strokeRGB.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
            strokeConverted = true
        }
        if !strokeConverted {
            throw SmokeFailure("idle chip stroke color could not be resolved")
        }
        if abs(br - sr) > 0.08 || abs(bg - sg) > 0.08 || abs(bb - sb) > 0.08 || abs(ba - sa) > 0.08 {
            throw SmokeFailure(
                "idle chip stroke should match Theme.Chip.outlineColor, got (\(br), \(bg), \(bb), \(ba))"
            )
        }
        guard let selectedColor = controller.smokeSelectedScopeChipTextColor else {
            throw SmokeFailure("selected scope chip should have a title color")
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var converted = false
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let selectedRGB = selectedColor.usingColorSpace(.sRGB),
                  let labelRGB = Theme.Ink.primary.usingColorSpace(.sRGB) else { return }
            selectedRGB.getRed(&r, green: &g, blue: &b, alpha: &a)
            labelRGB.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
            converted = true
        }
        if !converted {
            throw SmokeFailure("selected scope chip title color could not be resolved")
        }
        if abs(r - lr) > 0.15 || abs(g - lg) > 0.15 || abs(b - lb) > 0.15 {
            throw SmokeFailure("selected scope chip text should use Theme.Ink.primary, got \(selectedColor)")
        }
        guard let selectedFill = controller.smokeSelectedScopeChipFillColor else {
            throw SmokeFailure("selected scope chip should have a fill color")
        }
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        var fillConverted = false
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let fillRGB = NSColor(cgColor: selectedFill)?.usingColorSpace(.deviceRGB),
                  let controlRGB = Theme.Chip.selectedFill.usingColorSpace(.deviceRGB) else { return }
            fillRGB.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            controlRGB.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            fillConverted = true
        }
        if !fillConverted {
            throw SmokeFailure("selected scope chip fill color could not be resolved")
        }
        if abs(fr - cr) > 0.08 || abs(fg - cg) > 0.08 || abs(fb - cb) > 0.08 || abs(fa - ca) > 0.08 {
            throw SmokeFailure(
                "selected scope chip fill should match Theme.Chip.selectedFill, got (\(fr), \(fg), \(fb), \(fa))"
            )
        }
        if controller.smokeHasInboxGroupHeader {
            throw SmokeFailure("All view should not show an Inbox group header")
        }
        if let titleX = controller.smokeFirstGroupHeaderTitleMinX {
            if let allTitleX = controller.smokeAllTitleMinX {
                try assertClose(titleX, allTitleX + Theme.Size.listTextNudge, "group title aligns with All text", tolerance: 2)
            }
            guard let disclosureX = controller.smokeFirstGroupHeaderDisclosureMinX else {
                throw SmokeFailure("group header should have a trailing collapse control")
            }
            if disclosureX <= titleX + 20 {
                throw SmokeFailure(
                    "collapse control should sit on the trailing side, disclosure x=\(disclosureX) title x=\(titleX)"
                )
            }
        }
    }

    /// Every chrome frame (Input, Scope Bar, list, utility bar, every chip)
    /// sits on device pixels at the window's backing scale — a half-pixel
    /// edge blurs a 1 pt stroke — and every chip is `chipHeight` tall with
    /// an integral width.
    static func stepPixelAlignment(window: NSWindow, controller: MainViewController) throws {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let chips = controller.smokeChipFramesInWindow
        if chips.count < 5 {
            throw SmokeFailure("expected All, +, Resolved, Sort and Trash chips, got \(chips.map(\.label))")
        }
        for (label, frame) in controller.smokeChromeFramesInWindow + chips {
            let aligned = window.backingAlignedRect(frame, options: .alignAllEdgesNearest)
            if abs(aligned.minX - frame.minX) > 0.01 || abs(aligned.maxX - frame.maxX) > 0.01
                || abs(aligned.minY - frame.minY) > 0.01 || abs(aligned.maxY - frame.maxY) > 0.01 {
                throw SmokeFailure("\(label) is off the pixel grid at \(window.backingScaleFactor)x: \(frame)")
            }
        }
        for (label, frame) in chips {
            try assertClose(frame.height, Theme.Size.chipHeight, "\(label) height", tolerance: 0.01)
            if abs(frame.width - frame.width.rounded()) > 0.01 {
                throw SmokeFailure("\(label) width should be integral, got \(frame.width)")
            }
        }
    }

    /// Bars are transparent overlays on a full-height list (ui.md §4): no
    /// separator anywhere, the list spanning Input→bottom with the
    /// Scope Bar and utility bar over its ends, content resting just inside
    /// them, and the edge dissolve following the scroll position. Seeds
    /// enough rows to overflow, drives ↓ to the last row and ↑ back, and
    /// deletes the rows again so later steps see the list they expect.
    static func stepOverlayBars(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let input = controller.smokeInputFrame
        let list = controller.smokeScrollFrame
        let scope = controller.smokeScopeBarFrame
        let utility = controller.smokeUtilityBarFrame
        try assertClose(input.minY - list.maxY, Theme.Spacing.md, "list starts Spacing.md under the input, no separator")
        try assertClose(list.minY, 0, "list runs to the bottom of the surface")
        try assertClose(scope.maxY, list.maxY, "scope bar overlays the top of the list")
        try assertClose(scope.height, Theme.Size.scopeBarHeight, "scope bar overlay height")
        try assertClose(utility.minY, 0, "utility bar overlays the bottom of the list")
        try assertClose(utility.height, Theme.Size.utilityBarHeight, "utility bar overlay height")
        let insets = controller.smokeScrollInsets
        let scroller = controller.smokeScrollerInsets
        try assertClose(insets.top, Theme.Size.scopeBarHeight, "top content inset equals the scope bar")
        try assertClose(insets.bottom, Theme.Size.utilityBarHeight, "bottom content inset equals the utility bar")
        try assertClose(scroller.top, insets.top, "scroller stays clear of the scope bar")
        try assertClose(scroller.bottom, insets.bottom, "scroller stays clear of the utility bar")
        let trashInsets = controller.smokeTrashScrollInsets
        try assertClose(trashInsets.top, Theme.Size.scopeBarHeight, "trash list rests under its header bar")
        try assertClose(trashInsets.bottom, Theme.Size.utilityBarHeight, "trash list rests above its action bar")
        if controller.smokeHasDissolveMask {
            throw SmokeFailure("an empty list should not be masked")
        }

        var probes: [Record] = []
        for index in 0..<14 {
            probes.append(try createRecordSync(store: store, content: "smoke overlay \(index)"))
        }
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "overlay probe records visible") {
            controller.smokeVisibleRecords.count == probes.count
        }
        controller.view.layoutSubtreeIfNeeded()
        pump()
        guard let firstID = controller.smokeVisibleRecords.first?.id,
              let lastID = controller.smokeVisibleRecords.last?.id else {
            throw SmokeFailure("overlay probe records missing")
        }
        func assertRest(_ label: String) throws {
            let dissolve = controller.smokeDissolveState
            if dissolve.topActive || !dissolve.bottomActive {
                throw SmokeFailure("\(label): at rest only the bottom band should be on, got \(dissolve)")
            }
            guard let clearance = controller.smokeRowClearance(forRecordID: firstID) else {
                throw SmokeFailure("\(label): first row missing")
            }
            if clearance.top < insets.top - 0.5 {
                throw SmokeFailure("\(label): first row should start under the scope bar, clearance \(clearance.top)")
            }
        }
        try assertRest("after load")

        controller.focusInputAtEnd()
        for _ in 0..<probes.count {
            try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        }
        try waitUntil(showing: "↓ reached the last row") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord?.id == lastID
        }
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let atEnd = controller.smokeDissolveState
        if !atEnd.topActive || atEnd.bottomActive {
            throw SmokeFailure("at the end only the top band should be on, got \(atEnd)")
        }
        guard let endClearance = controller.smokeRowClearance(forRecordID: lastID) else {
            throw SmokeFailure("last row missing after ↓")
        }
        if endClearance.bottom < insets.bottom - 0.5 {
            throw SmokeFailure("last row should scroll clear of the utility bar, clearance \(endClearance.bottom)")
        }

        // Edit-commit on the last row must not scroll it under the bar
        // (a reload after commit would leave the list one row up).
        try sendReturn(window: window)
        try waitUntil(showing: "inline edit began on the last row") { controller.smokeIsEditingRecord(id: lastID) }
        try sendReturn(window: window)
        try waitUntil(showing: "inline edit committed on the last row") {
            !controller.smokeIsEditingRecord(id: lastID) && controller.smokeIsTableFirstResponder()
                && controller.smokeSelectedRecord?.id == lastID
        }
        controller.view.layoutSubtreeIfNeeded()
        pump()
        pump()
        func assertInBand(_ id: String, _ label: String) throws {
            controller.view.layoutSubtreeIfNeeded()
            pump()
            guard let clearance = controller.smokeRowClearance(forRecordID: id) else {
                throw SmokeFailure("\(label): focused row missing")
            }
            if clearance.bottom < insets.bottom - 0.5 || clearance.top < insets.top - 0.5 {
                throw SmokeFailure("\(label): focused row should sit between the bars, clearance top \(clearance.top) bottom \(clearance.bottom)")
            }
        }
        try assertInBand(lastID, "after edit commit on the last row")

        // Resolve on the last row: it leaves the list, focus inherits the
        // new last row, which must also sit inside the band; ⌘Z restores.
        let visibleBeforeResolve = controller.smokeVisibleRecords
        try sendSpecial(keyCode: KeyCode.space, characters: " ", window: window)
        try waitUntil(showing: "last row resolved and gone") {
            !controller.smokeVisibleRecords.contains { $0.id == lastID } && controller.smokeSelectedRecord != nil
        }
        guard let afterResolveID = controller.smokeSelectedRecord?.id else { throw SmokeFailure("no focus after resolve") }
        try assertEqual(afterResolveID, visibleBeforeResolve[visibleBeforeResolve.count - 2].id, "focus inherits the previous row after resolving the last")
        try assertInBand(afterResolveID, "after resolving the last row")
        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z reopened the last row") { controller.smokeVisibleRecords.contains { $0.id == lastID } }

        // Trash on the last row, same rule; ⌘Z restores.
        controller.focusInputAtEnd()
        for _ in 0..<probes.count {
            try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        }
        try waitUntil(showing: "↓ back on the last row") { controller.smokeSelectedRecord?.id == lastID }
        try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
        try waitUntil(showing: "last row trashed") {
            !controller.smokeVisibleRecords.contains { $0.id == lastID } && controller.smokeSelectedRecord != nil
        }
        guard let afterTrashID = controller.smokeSelectedRecord?.id else { throw SmokeFailure("no focus after trash") }
        try assertInBand(afterTrashID, "after trashing the last row")
        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z restored the last row") { controller.smokeVisibleRecords.contains { $0.id == lastID } }
        try waitUntil(showing: "search settled after undo") { controller.smokeSearchSettled }

        for _ in 0..<(probes.count - 1) {
            try sendArrow(.upArrow, keyCode: KeyCode.upArrow, window: window)
        }
        try waitUntil(showing: "↑ back at the first row") {
            controller.smokeSelectedRecord?.id == firstID
        }
        controller.view.layoutSubtreeIfNeeded()
        pump()
        try assertRest("after ↑")

        for record in probes {
            try applySync("overlay probe trashed") { store.moveToTrash(id: record.id, completion: $0) }
            try applySync("overlay probe deleted") { store.permanentlyDelete(id: record.id, completion: $0) }
        }
        controller.focusInputAtEnd()
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "overlay probe records gone") { controller.smokeVisibleRecords.isEmpty }
        try assertEqual(try trashedSync(store: store).count, 0, "Trash empty after the overlay step")
        try waitUntil(showing: "Universal Input focused after the overlay step") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// The rails are optical (ui.md §3): measured on rendered ink, not on
    /// frames, against `Theme.Optical`. Any token change that moves a
    /// glyph off the eye-level rule fails here.
    static func stepOpticalRails(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        // A project with one record puts a group header (chevron) on screen
        // next to the Inbox rows; both go away again at the end.
        var created: Result<Project, Error>?
        store.projects.createProject(name: "Rails") { created = $0 }
        try waitUntil(showing: "rails probe project created") { created != nil }
        let project = try created!.get()
        let probe = try createRecordSync(store: store, content: "Optical rail probe", projectID: project.id)
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "rails probe listed under its group header") {
            controller.smokeVisibleRecords.contains { $0.id == probe.id } && controller.smokeFirstGroupHeaderDisclosureMinX != nil
        }
        defer {
            try? applySync("rails probe trashed") { store.moveToTrash(id: probe.id, completion: $0) }
            try? applySync("rails probe deleted") { store.permanentlyDelete(id: probe.id, completion: $0) }
            try? applySync("rails probe project deleted") { store.projects.deleteProject(id: project.id, completion: $0) }
            controller.reloadProjectsAndSearch()
            try? waitUntil(showing: "rails probe gone") { !controller.smokeVisibleRecords.contains { $0.id == probe.id } }
        }
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused before the optical rail check") { controller.smokeIsInputFirstResponder() }
        guard let rails = controller.smokeRailFrames() else {
            throw SmokeFailure("optical rails need a record row and a group header on screen")
        }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        pump()
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SmokeFailure("no bitmap for the optical rail check")
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        func luminance(atWindowPoint p: NSPoint) -> CGFloat {
            let x = min(max(Int(p.x * scale), 0), rep.pixelsWide - 1)
            let y = min(max(Int((content.bounds.height - p.y) * scale), 0), rep.pixelsHigh - 1)
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255
        }
        /// Ink bounding box inside `rect` (expanded 2pt), relative to the
        /// surface sampled at `background`; window coordinates.
        func inkBox(in rect: NSRect, background: NSPoint, label: String) throws -> NSRect {
            let bg = luminance(atWindowPoint: background)
            let r = rect.insetBy(dx: -2, dy: -2)
            var minX: CGFloat?, maxX: CGFloat?, minY: CGFloat?, maxY: CGFloat?
            var px = r.minX
            while px <= r.maxX {
                var py = r.minY
                while py <= r.maxY {
                    if abs(luminance(atWindowPoint: NSPoint(x: px, y: py)) - bg) > 40 {
                        minX = min(minX ?? px, px); maxX = max(maxX ?? px, px)
                        minY = min(minY ?? py, py); maxY = max(maxY ?? py, py)
                    }
                    py += 1 / scale
                }
                px += 1 / scale
            }
            guard let minX, let maxX, let minY, let maxY else { throw SmokeFailure("\(label): no ink found in \(rect)") }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        func inkSpan(in rect: NSRect, background: NSPoint, label: String) throws -> ClosedRange<CGFloat> {
            let box = try inkBox(in: rect, background: background, label: label)
            return box.minX...box.maxX
        }
        let corner = NSPoint(x: Theme.Size.windowInset / 2, y: Theme.Size.windowInset / 2)
        let allInk = try inkSpan(in: rails.allTitle, background: NSPoint(x: rails.allChip.minX + 4, y: rails.allChip.midY), label: "All letters")
        let plusInk = try inkSpan(in: rails.plusChip.insetBy(dx: 4, dy: 4), background: NSPoint(x: rails.plusChip.minX + 4, y: rails.plusChip.midY), label: "+ glyph")
        let priorityInk = try inkSpan(in: rails.priority, background: corner, label: "Priority glyph")
        let timeInk = try inkSpan(in: rails.time, background: corner, label: "date")
        let chevronInk = try inkSpan(in: rails.chevron, background: corner, label: "chevron")
        writeLine(String(
            format: "OPTICAL All %.1f P %.1f | date→%.1f chevron→%.1f plus→%.1f (chevron mid %.1f, plus mid %.1f)",
            allInk.lowerBound, priorityInk.lowerBound, timeInk.upperBound, chevronInk.upperBound, plusInk.upperBound,
            (chevronInk.lowerBound + chevronInk.upperBound) / 2, (plusInk.lowerBound + plusInk.upperBound) / 2
        ))
        let tol = Theme.Optical.tolerance
        try assertClose(priorityInk.lowerBound - allInk.lowerBound, Theme.Optical.listTextAfterAll, "left rail: list text ink vs All's first letter", tolerance: tol)
        try assertClose(chevronInk.upperBound - timeInk.upperBound, Theme.Optical.timeInsideChevron, "right rail: date ink tucks inside the chevron", tolerance: tol)
        try assertClose(
            (chevronInk.lowerBound + chevronInk.upperBound) / 2 - (plusInk.lowerBound + plusInk.upperBound) / 2,
            Theme.Optical.chevronUnderPlus, "right rail: chevron ink centred under the + glyph", tolerance: tol
        )

        // Symbol-only chips: the glyph's ink is centred in the chip on both
        // axes (an attributed-title attachment sits ~1pt low), and swapping the Resolved
        // glyph does not change its ink width.
        var icons = controller.smokeUtilityIconFramesInWindow
        icons.append((label: "+", frame: rails.plusChip))
        var report: [String] = []
        for (label, frame) in icons {
            let ink = try inkBox(in: frame.insetBy(dx: 3, dy: 3), background: NSPoint(x: frame.minX + 2, y: frame.midY), label: "\(label) glyph")
            report.append(String(format: "%@ %.1fx%.1f dx %.2f dy %.2f", label, ink.width, ink.height, ink.midX - frame.midX, ink.midY - frame.midY))
            try assertClose(ink.midX - frame.midX, Theme.Optical.iconCentred, "\(label) glyph centred horizontally", tolerance: tol)
            try assertClose(ink.midY - frame.midY, Theme.Optical.iconCentred, "\(label) glyph centred vertically", tolerance: tol)
        }
        writeLine("OPTICAL icons " + report.joined(separator: " | "))
        guard let eyeFrame = icons.first(where: { $0.label == "eye" })?.frame else { return }
        let eyeOff = try inkBox(in: eyeFrame.insetBy(dx: 3, dy: 3), background: NSPoint(x: eyeFrame.minX + 2, y: eyeFrame.midY), label: "eye.slash")
        controller.smokeClickResolved()
        pump()
        content.cacheDisplay(in: content.bounds, to: rep)
        let eyeOn = try inkBox(in: eyeFrame.insetBy(dx: 3, dy: 3), background: NSPoint(x: eyeFrame.minX + 2, y: eyeFrame.midY), label: "eye")
        controller.smokeClickResolved()
        pump()
        try assertClose(eyeOn.width, eyeOff.width, "Resolved glyph keeps its ink width across the swap", tolerance: tol)
        try assertClose(eyeOn.midX, eyeOff.midX, "Resolved glyph keeps its centre across the swap", tolerance: tol)
    }

    static func stepUtilityBar(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        let resolved = controller.smokeResolvedChip
        let sort = controller.smokeSortChip
        let trash = controller.smokeTrashChip

        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let bar = controller.smokeUtilityBarFrame
        for (chip, label) in [(resolved, "resolved"), (sort, "sort"), (trash, "trash")] {
            if !chip.refusesFirstResponder {
                throw SmokeFailure("\(label) chip must refuse first responder")
            }
            let frame = controller.smokeUtilityControlFrame(chip)
            try assertClose(frame.height, Theme.Size.chipHeight, "\(label) chip height")
            // Square icon buttons (ui.md §5): no title, glyph only.
            try assertClose(frame.width, Theme.Size.chipHeight, "\(label) chip is square")
            if !chip.iconOnly || chip.symbolName == nil || !chip.chipTitle.isEmpty {
                throw SmokeFailure("\(label) chip should be an icon-only button")
            }
            // Same air below the buttons as beside them (ui.md §5).
            try assertClose(frame.minY - bar.minY, Theme.Size.windowInset, "\(label) chip sits windowInset off the bottom edge")
            // Bar buttons are filled rounded rects, not Scope Bar capsules
            // (ui.md §5): radius is the control token, no stroke.
            if chip.style != .filled {
                throw SmokeFailure("\(label) chip should use the filled style")
            }
            chip.layoutSubtreeIfNeeded()
            try assertClose(chip.layer?.cornerRadius ?? -1, Theme.Radius.control, "\(label) chip corner radius")
            try assertClose(chip.layer?.borderWidth ?? -1, 0, "\(label) chip has no stroke")
        }
        let resolvedFrame = controller.smokeUtilityControlFrame(resolved)
        try assertClose(resolvedFrame.minX, Theme.Size.windowInset, "resolved chip leading on the chip rail")
        try assertClose(
            controller.smokeUtilityControlFrame(sort).minX,
            resolvedFrame.maxX + Theme.Size.chipSpacing,
            "sort chip follows resolved at chipSpacing"
        )
        try assertClose(
            controller.smokeUtilityControlFrame(trash).minX,
            controller.smokeUtilityControlFrame(sort).maxX + Theme.Size.chipSpacing,
            "trash chip closes the function group after sort while no conflicts are shown"
        )

        // Resolved: symbol and tooltip mirror the preference; toggling never
        // moves first responder away from Universal Input.
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused before toggling Resolved") { controller.smokeIsInputFirstResponder() }
        try assertEqual(resolved.symbolName, "eye.slash", "resolved chip starts off")
        try assertEqual(Preferences.showResolved, false, "Show Resolved starts off")
        try assertEqual(resolved.toolTip, "Show Resolved", "resolved tooltip when off")
        let widthOff = controller.smokeUtilityControlFrame(resolved).width
        controller.smokeClickResolved()
        pump()
        controller.view.layoutSubtreeIfNeeded()
        try assertEqual(resolved.symbolName, "eye", "resolved chip on after click")
        try assertEqual(Preferences.showResolved, true, "Preferences.showResolved follows the chip")
        try assertEqual(resolved.toolTip, "Hide Resolved", "resolved tooltip when on")
        try assertClose(controller.smokeUtilityControlFrame(resolved).width, widthOff, "resolved chip width is stable across the symbol swap")
        if !controller.smokeIsInputFirstResponder() {
            throw SmokeFailure("toggling Resolved must not steal first responder from Universal Input")
        }
        controller.smokeClickResolved()
        pump()
        try assertEqual(resolved.symbolName, "eye.slash", "resolved chip off after second click")
        try assertEqual(Preferences.showResolved, false, "Preferences.showResolved restored")

        // Sort: the chip is a two-state toggle (Newest ⇄ Priority). Give the
        // older record a higher priority so the flip visibly re-orders.
        try assertEqual(sort.symbolName, "clock", "sort chip shows the date glyph while newest first")
        let newestFirst = controller.smokeVisibleRecords.map(\.id)
        try assertEqual(newestFirst.count, 2, "two records before the sort check")
        let older = newestFirst[1]
        try applySync("raise the older record to P1") { store.updatePriority(id: older, priority: Priority.p1.rawValue, completion: $0) }
        controller.smokeToggleSort()
        try waitUntil(showing: "list re-ordered by priority") {
            controller.smokeVisibleRecords.map(\.id) == [older, newestFirst[0]]
        }
        try assertEqual(sort.symbolName, "flag", "sort chip flips to the priority glyph")
        try assertEqual(Preferences.sortOrder, .priority, "Preferences.sortOrder follows the toggle")
        try applySync("restore the older record to P2") { store.updatePriority(id: older, priority: Priority.p2.rawValue, completion: $0) }
        controller.smokeToggleSort()
        try waitUntil(showing: "list restored newest first") {
            controller.smokeVisibleRecords.map(\.id) == newestFirst
                && controller.smokeVisibleRecords.first { $0.id == older }?.priority == Priority.p2.rawValue
        }
        try assertEqual(sort.symbolName, "clock", "sort chip flips back")
        try assertEqual(Preferences.sortOrder, .newestFirst, "Preferences.sortOrder restored")

        // Trash action bar (hidden surface; no display needed for these).
        let actions = controller.smokeTrashActionChips
        try assertEqual(actions.map(\.symbolName), ["arrow.uturn.backward", "xmark.bin"], "trash action chips are icons")
        for chip in actions where !chip.iconOnly || !chip.chipTitle.isEmpty {
            throw SmokeFailure("trash action chips should be icon-only")
        }
        for chip in actions where !chip.refusesFirstResponder {
            throw SmokeFailure("\(chip.chipTitle) must refuse first responder")
        }
        for chip in actions where chip.style != .filled {
            throw SmokeFailure("\(chip.chipTitle) should use the filled style")
        }
        if controller.smokeTrashBackChip.style != .plain {
            throw SmokeFailure("trash Back should be the plain style")
        }
        try assertEqual(controller.smokeTrashBackChip.symbolName, "chevron.left", "trash back chip glyph")

    }
}
