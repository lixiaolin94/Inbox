#if DEBUG
import AppKit

/// In-process UI smoke driven by `--ui-smoke`.
///
/// Synthesizes `NSEvent.keyEvent` and delivers them through `NSApp.sendEvent`
/// (⌘ shortcuts via `performKeyEquivalent`) so the real responder chain runs.
/// Chinese / IME input is not covered: composition cannot be synthesized
/// with key events.
enum UISmokeRunner {
    static func start(window: NSWindow, controller: MainViewController, store: RecordStore) {
        // A Timer source, not `DispatchQueue.main.async`: store completions
        // also hop to the main queue, and that queue is not re-entrant. A
        // nested run loop from a GCD main-queue block would deadlock waiting
        // for those completions.
        Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
            run(window: window, controller: controller, store: store)
        }
    }

    private static func run(window: NSWindow, controller: MainViewController, store: RecordStore) {
        setbuf(stdout, nil)
        do {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            controller.focusInputAtEnd()

            try waitUntil(showing: "window visible") { window.isVisible }
            // A Terminal-launched binary may not be allowed to steal key
            // focus. Keep trying briefly, then continue and deliver events
            // to the window directly if it still is not key.
            let keyDeadline = Date().addingTimeInterval(0.4)
            while !window.isKeyWindow, Date() < keyDeadline {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                pump()
            }
            controller.focusInputAtEnd()
            try stepWindowGeometry(window: window, controller: controller)
            try stepChromeGeometry(window: window, controller: controller)
            try stepPixelAlignment(window: window, controller: controller)
            try stepOverlayBars(window: window, controller: controller, store: store)
            try stepScopeBarOverflow()
            try stepA(window: window, controller: controller)
            try stepB(window: window, controller: controller, store: store)
            try stepC(window: window, controller: controller, store: store)
            try stepUtilityBar(window: window, controller: controller, store: store)
            try stepConflicts(window: window, controller: controller, store: store)
            try stepTrashSurface(window: window, controller: controller)
            try stepUndoResolveAndMove(window: window, controller: controller, store: store)
            let pair = try stepD(window: window, controller: controller)
            try stepE(window: window, controller: controller, store: store, betaID: pair.betaID)
            try stepF(window: window, controller: controller, store: store, betaID: pair.betaID, alphaID: pair.alphaID)
            try stepG(window: window, controller: controller, store: store, alphaID: pair.alphaID)
            try stepH(window: window, controller: controller, store: store, alphaID: pair.alphaID)
            try stepMultilineRowHeight(window: window, controller: controller)
            try stepWindowReopen(window: window, controller: controller)
            try stepSettings(window: window)
            if let directory = LaunchConfiguration.parse(CommandLine.arguments).snapshotDirectory {
                try stepSnapshots(window: window, controller: controller, store: store, directory: directory)
            }
            writeLine("UI-SMOKE PASS")
            exit(0)
        } catch {
            writeLine("UI-SMOKE FAIL: \(error)")
            exit(1)
        }
    }

    // MARK: - Steps

    /// Window opens at 720×480, can grow, and cannot shrink below minSize.
    private static func stepWindowGeometry(window: NSWindow, controller: MainViewController) throws {
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
    private static func stepScopeBarOverflow() throws {
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

    private static func stepChromeGeometry(window: NSWindow, controller: MainViewController) throws {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let input = controller.smokeInputFrame
        try assertClose(input.height, Theme.Size.inputHeight, "input chrome height")
        if input.minX < 12 {
            throw SmokeFailure("input should float inset from the leading edge, got x=\(input.minX)")
        }
        if abs(input.width - (controller.view.bounds.width - input.minX * 2)) > 2 {
            throw SmokeFailure("input should keep matching side insets, frame=\(input) view=\(controller.view.bounds)")
        }
        if controller.smokeInputPlaceholder != "Record or search…" {
            throw SmokeFailure(
                "input placeholder should be 'Record or search…', got '\(controller.smokeInputPlaceholder)'"
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
    private static func stepPixelAlignment(window: NSWindow, controller: MainViewController) throws {
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
    private static func stepOverlayBars(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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

    /// Bottom bar: the three chips are `ScopeChipButton`s on the chip rails
    /// (the custom chip is kept here on purpose — see MainViewController),
    /// Resolved toggles state without moving first responder, the sort
    /// chip's face and menu stay in sync and a pick re-orders the list.
    private static func stepUtilityBar(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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
            try assertClose(frame.midY, bar.midY, "\(label) chip centred in the utility bar")
        }
        let resolvedFrame = controller.smokeUtilityControlFrame(resolved)
        try assertClose(resolvedFrame.minX, Theme.Size.contentInset, "resolved chip leading on the chip rail")
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
        try assertEqual(sort.chipTitle, Preferences.sortOrder.chipTitle, "sort chip shows the current sort")
        let newestFirst = controller.smokeVisibleRecords.map(\.id)
        try assertEqual(newestFirst.count, 2, "two records before the sort check")
        let older = newestFirst[1]
        try applySync("raise the older record to P1") { store.updatePriority(id: older, priority: Priority.p1.rawValue, completion: $0) }
        controller.smokeToggleSort()
        try waitUntil(showing: "list re-ordered by priority") {
            controller.smokeVisibleRecords.map(\.id) == [older, newestFirst[0]]
        }
        try assertEqual(sort.chipTitle, RecordSort.priority.chipTitle, "sort chip flips to Priority")
        try assertEqual(Preferences.sortOrder, .priority, "Preferences.sortOrder follows the toggle")
        try applySync("restore the older record to P2") { store.updatePriority(id: older, priority: Priority.p2.rawValue, completion: $0) }
        controller.smokeToggleSort()
        try waitUntil(showing: "list restored newest first") {
            controller.smokeVisibleRecords.map(\.id) == newestFirst
                && controller.smokeVisibleRecords.first { $0.id == older }?.priority == Priority.p2.rawValue
        }
        try assertEqual(sort.chipTitle, RecordSort.newestFirst.chipTitle, "sort chip flips back")
        try assertEqual(Preferences.sortOrder, .newestFirst, "Preferences.sortOrder restored")

        // Trash action bar (hidden surface; no display needed for these).
        let actions = controller.smokeTrashActionChips
        try assertEqual(actions.map(\.chipTitle), ["Restore", "Delete Permanently"], "trash action chips")
        for chip in actions where !chip.refusesFirstResponder {
            throw SmokeFailure("\(chip.chipTitle) must refuse first responder")
        }
        try assertEqual(controller.smokeTrashHintTexts, ["↵ Restore", "⌫ Delete", "esc Back"], "trash action bar hints")

        // Key hints (ui.md §5): trailing on the rail, following the focus
        // state, never taking the mouse or first responder.
        controller.focusInputAtEnd()
        try waitUntil(showing: "input hints") { controller.smokeHintTexts == ["↵ Create", "↓ List"] }
        controller.view.layoutSubtreeIfNeeded()
        guard let hintFrame = controller.smokeHintBarFrame else {
            throw SmokeFailure("hint bar should fit at \(bar.width)pt")
        }
        try assertClose(bar.width - hintFrame.maxX, Theme.Size.contentInset, "hint bar trailing on the chip rail")
        try assertClose(hintFrame.midY, bar.midY, "hint bar centred in the utility bar")
        if hintFrame.minX < controller.smokeFunctionGroupMaxX + Theme.Spacing.xl - 0.5 {
            throw SmokeFailure("hint bar should sit Spacing.xl clear of the function group, frame=\(hintFrame)")
        }
        if controller.smokeHintBarTakesMouse {
            throw SmokeFailure("hint bar must not be hit-testable")
        }
        if !controller.smokeIsInputFirstResponder() {
            throw SmokeFailure("hint bar must not move first responder away from Universal Input")
        }
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "row hints after ↓") {
            controller.smokeIsTableFirstResponder()
                && Array(controller.smokeHintTexts.prefix(3)) == ["↵ Edit", "␣ Resolve", "⌫ Trash"]
        }
        controller.focusInputAtEnd()
        try waitUntil(showing: "input hints restored") { controller.smokeHintTexts == ["↵ Create", "↓ List"] }

        // At the minimum width the rule decides, not a fixed outcome: shown
        // only while the smallest tier fits beside the function group.
        let originalFrame = window.frame
        var narrow = originalFrame
        narrow.size.width = Theme.Size.windowMinimum.width
        window.setFrame(narrow, display: true)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let narrowBar = controller.smokeUtilityBarFrame
        let needed = controller.smokeFunctionGroupMaxX + Theme.Spacing.xl
            + controller.smokeHintBarFittingWidth + Theme.Size.contentInset
        if let frame = controller.smokeHintBarFrame {
            if needed > narrowBar.width + 0.5 {
                throw SmokeFailure("hint bar shown at \(narrowBar.width)pt though it needs \(needed)pt")
            }
            try assertClose(narrowBar.width - frame.maxX, Theme.Size.contentInset, "hint bar trailing on the rail at minimum width")
        } else if needed <= narrowBar.width {
            throw SmokeFailure("hint bar hidden at \(narrowBar.width)pt though \(needed)pt fits")
        }
        window.setFrame(originalFrame, display: true)
        window.layoutIfNeeded()
        pump()
        try waitUntil(showing: "input hints after restoring the width") { controller.smokeHintTexts == ["↵ Create", "↓ List"] }
    }

    /// Conflict centre (PRD §15.3): a pair manufactured straight in the DB
    /// badges both rows and raises the utility-bar chip; the chip narrows
    /// the list to the pair without moving first responder; Keep This from
    /// the duplicate's context menu trashes the original and settles the
    /// pair. Leaves the list as it found it (alpha, beta; Trash empty) by
    /// restoring the original and resolving both probe records away.
    private static func stepConflicts(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        let chip = controller.smokeConflictsChip
        try assertEqual(chip.isHidden, true, "conflicts chip hidden while there are no conflicts")
        if !chip.refusesFirstResponder {
            throw SmokeFailure("conflicts chip must refuse first responder")
        }
        let before = controller.smokeVisibleRecords.map(\.id)
        guard let plainID = before.first else {
            throw SmokeFailure("expected a record outside the pair before the conflict step")
        }
        let original = try createRecordSync(store: store, content: "smoke conflict original")
        let duplicate = try createRecordSync(store: store, content: "smoke conflict duplicate")
        try applySync("duplicate marked as a conflict copy") {
            store.smokeMarkAsConflictDuplicate(id: duplicate.id, of: original.id, completion: $0)
        }
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "conflicts chip shows the pair") {
            controller.smokeVisibleRecords.count == before.count + 2 && !chip.isHidden && chip.chipTitle == "1 conflict"
        }
        controller.view.layoutSubtreeIfNeeded()
        let chipFrame = controller.smokeUtilityControlFrame(chip)
        try assertClose(
            chipFrame.minX,
            controller.smokeUtilityControlFrame(controller.smokeSortChip).maxX + Theme.Size.chipSpacing,
            "conflicts chip follows sort at chipSpacing"
        )
        try assertClose(chipFrame.midY, controller.smokeUtilityBarFrame.midY, "conflicts chip centred in the utility bar")
        try assertEqual(chip.symbolName, "exclamationmark.triangle", "conflicts chip symbol")
        for record in [original, duplicate] where !controller.smokeIsConflictBadgeShown(forRecordID: record.id) {
            throw SmokeFailure("'\(record.content)' should carry the Conflict badge")
        }
        if controller.smokeIsConflictBadgeShown(forRecordID: plainID) {
            throw SmokeFailure("a record outside the pair must not carry the Conflict badge")
        }
        try assertEqual(
            controller.smokeRowHeight(forRecordID: duplicate.id),
            controller.smokeRowHeight(forRecordID: plainID),
            "badge does not change the row height"
        )
        if let directory = LaunchConfiguration.parse(CommandLine.arguments).snapshotDirectory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            window.appearance = NSAppearance(named: .aqua)
            try renderSnapshot("main-conflict-aqua-720", window: window, controller: controller, directory: directory)
            window.appearance = nil
            pump()
        }

        // Filter to the pair and back; Universal Input keeps first responder.
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused before filtering conflicts") { controller.smokeIsInputFirstResponder() }
        controller.smokeClickConflictsChip()
        try waitUntil(showing: "conflicts chip filters the list to the pair") {
            chip.isSelectedScope && Set(controller.smokeVisibleRecords.map(\.id)) == [original.id, duplicate.id]
        }
        if !controller.smokeIsInputFirstResponder() {
            throw SmokeFailure("filtering conflicts must not steal first responder from Universal Input")
        }
        controller.smokeClickConflictsChip()
        try waitUntil(showing: "second click restores the full list") {
            !chip.isSelectedScope && controller.smokeVisibleRecords.count == before.count + 2
        }
        if !controller.smokeIsInputFirstResponder() {
            throw SmokeFailure("clearing the conflicts filter must not steal first responder from Universal Input")
        }

        // Resolve from the duplicate's context menu: Keep This trashes the
        // original, clears the marker, and leaves Row Focus on the survivor.
        try assertEqual(
            Array(controller.smokeContextMenuTitles(forRecordID: duplicate.id)?.prefix(2) ?? []),
            ["Resolve Conflict", "Move to"],
            "Resolve Conflict sits above Move to on a conflicted row"
        )
        try assertEqual(
            controller.smokeResolveConflictMenuTitles(forRecordID: duplicate.id),
            ["Keep This", "Keep Other", "Keep Both"],
            "resolution choices"
        )
        if !controller.smokeResolveConflict(id: duplicate.id, resolution: .keepThis) {
            throw SmokeFailure("Keep This menu item missing on the duplicate")
        }
        try waitUntil(showing: "Keep This trashed the original and settled the pair") {
            chip.isHidden
                && !controller.smokeVisibleRecords.contains { $0.id == original.id }
                && controller.smokeVisibleRecords.contains { $0.id == duplicate.id }
                && !controller.smokeIsConflictBadgeShown(forRecordID: duplicate.id)
        }
        try assertEqual(try trashedSync(store: store).map(\.id), [original.id], "original in Trash after Keep This")
        guard let settled = try store.recordByID(duplicate.id) else {
            throw SmokeFailure("DB missing the duplicate after Keep This")
        }
        try assertEqual(settled.conflictOf, nil, "duplicate marker cleared")
        try assertEqual(controller.smokeContextMenuTitles(forRecordID: duplicate.id)?.first, "Move to", "no Resolve Conflict item once settled")
        try waitUntil(showing: "Row Focus on the surviving row") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord?.id == duplicate.id
        }

        try applySync("original restored from Trash") { done in
            store.restoreFromTrash(id: original.id) { done($0.map { _ in () }) }
        }
        for record in [original, duplicate] {
            try applySync("'\(record.content)' resolved out of the list") {
                store.setStatus(id: record.id, status: .resolved, completion: $0)
            }
        }
        controller.focusInputAtEnd()
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "list back to the records before the conflict step") {
            controller.smokeVisibleRecords.map(\.id) == before && chip.isHidden
        }
        try assertEqual(try trashedSync(store: store).count, 0, "Trash empty after the conflict step")
        try waitUntil(showing: "Universal Input focused after the conflict step") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// ⌘Z covers Resolve and Move as well as Move to Trash: a fresh record
    /// is resolved with Space and undone back to Open, then moved to a new
    /// Project and undone back to Inbox. Cleans up after itself so later
    /// steps see the list they expect.
    private static func stepUndoResolveAndMove(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        let record = try createRecordSync(store: store, content: "smoke undo probe")
        var projectID: String?
        try applySync("create the undo probe project") { done in
            store.projects.createProject(name: "Undo Probe") { done($0.map { _ in () }) }
        }
        var projects: [Project] = []
        try applySync("list projects") { done in store.projects.listProjects { projects = (try? $0.get()) ?? []; done(.success(())) } }
        projectID = projects.first { $0.name == "Undo Probe" }?.id
        guard let probeProject = projectID else { throw SmokeFailure("undo probe project missing") }
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "undo probe listed") { controller.smokeVisibleRecords.contains { $0.id == record.id } }

        // Resolve → ⌘Z reopens.
        controller.focusInputAtEnd()
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "undo probe focused") { controller.smokeSelectedRecord?.id == record.id }
        try sendSpecial(keyCode: KeyCode.space, characters: " ", window: window)
        try waitUntil(showing: "undo probe resolved and gone") { !controller.smokeVisibleRecords.contains { $0.id == record.id } }
        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z reopened the undo probe") {
            controller.smokeVisibleRecords.first { $0.id == record.id }?.status == RecordStatus.open.rawValue
        }

        // Move → ⌘Z moves it back to Inbox.
        controller.smokeMoveRecords(ids: [record.id], to: probeProject)
        try waitUntil(showing: "undo probe moved to the project") {
            controller.smokeVisibleRecords.first { $0.id == record.id }?.projectID == probeProject
        }
        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z moved the undo probe back to Inbox") {
            controller.smokeVisibleRecords.first { $0.id == record.id }?.projectID == nil
        }

        // Clean up: trash + permanently delete the probe, delete the project.
        try applySync("trash the undo probe") { store.moveToTrash(id: record.id, completion: $0) }
        try applySync("delete the undo probe") { store.permanentlyDelete(id: record.id, completion: $0) }
        try applySync("delete the undo probe project") { store.projects.deleteProject(id: probeProject, completion: $0) }
        controller.reloadProjectsAndSearch()
        try waitUntil(showing: "undo probe cleaned up") { !controller.smokeVisibleRecords.contains { $0.id == record.id } }
        controller.focusInputAtEnd()
    }

    /// Trash chip opens the secondary surface with its table focused; Esc
    /// (NSTableView → cancelOperation up the responder chain to
    /// TrashViewController) returns to the main surface with Universal
    /// Input focused. Guards the Esc path after the dead
    /// `onRequestEscape` closure was removed.
    private static func stepTrashSurface(window: NSWindow, controller: MainViewController) throws {
        try assertEqual(controller.smokeIsShowingTrash, false, "main surface showing before opening Trash")
        controller.smokeOpenTrash()
        try waitUntil(showing: "Trash surface visible") { controller.smokeIsShowingTrash }
        try waitUntil(showing: "Trash table is first responder") { controller.smokeTrashTableIsFirstResponder }
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "Esc returned to the main surface") { !controller.smokeIsShowingTrash }
        try waitUntil(showing: "Universal Input focused after leaving Trash") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// ⌘, opens the Settings window; close it so later steps keep the main window.
    private static func stepSettings(window: NSWindow) throws {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            throw SmokeFailure("NSApp.delegate is not AppDelegate")
        }
        try sendCommand(",", keyCode: KeyCode.comma, window: window)
        try waitUntil(showing: "Settings window visible") {
            appDelegate.smokeSettingsWindowVisible()
        }
        appDelegate.smokeCloseSettings()
        try waitUntil(showing: "Settings window hidden") {
            !appDelegate.smokeSettingsWindowVisible()
        }
        window.makeKeyAndOrderFront(nil)
        pump()
    }

    /// performClose hides (S5 resident window); presentMainWindow restores
    /// the same size and puts the caret back in Universal Input.
    private static func stepWindowReopen(window: NSWindow, controller: MainViewController) throws {
        try assertContentSize(
            of: window,
            equals: Theme.Size.windowDefault,
            "content size before close"
        )
        window.performClose(nil)
        try waitUntil(showing: "window hidden after performClose") { !window.isVisible }

        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            throw SmokeFailure("NSApp.delegate is not AppDelegate")
        }
        appDelegate.presentMainWindow()
        try waitUntil(showing: "window visible after presentMainWindow") { window.isVisible }
        try assertContentSize(
            of: window,
            equals: Theme.Size.windowDefault,
            "content size after close and presentMainWindow"
        )
        try waitUntil(showing: "Universal Input is first responder after reopen") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }

        // Warm activation (PRD §17.1): the app's own share of "window
        // hidden → visible with the caret in Input". The Dock / ⌘Tab /
        // launcher hop before `presentMainWindow` is the system's.
        var samples: [Double] = []
        for _ in 0..<5 {
            window.performClose(nil)
            try waitUntil(showing: "window hidden before warm-activation sample") { !window.isVisible }
            let start = DispatchTime.now().uptimeNanoseconds
            appDelegate.presentMainWindow()
            window.displayIfNeeded()
            try waitUntil(showing: "warm-activation sample visible") {
                window.isVisible && controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        samples.sort()
        writeLine(String(format: "PERF warm-activation ms: min %.1f median %.1f max %.1f", samples[0], samples[2], samples[4]))
        if samples[2] > 100 {
            throw SmokeFailure("warm activation median \(samples[2]) ms exceeds the 100 ms budget")
        }
    }

    /// a. Universal Input is first responder (field editor).
    private static func stepA(window: NSWindow, controller: MainViewController) throws {
        controller.focusInputAtEnd()
        try waitUntil(showing: "Universal Input is first responder (field editor)") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// b. Type "smoke alpha" + Return → 1 row, DB has 1, Input cleared and focused.
    private static func stepB(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        try typeText("smoke alpha", window: window, controller: controller)
        try sendReturn(window: window)
        try waitUntil(showing: "1 visible record after creating 'smoke alpha'") {
            controller.smokeVisibleRecords.count == 1
                && controller.smokeInputString.isEmpty
                && controller.smokeIsInputFirstResponder()
        }
        let db = try searchSync(store: store, includeResolved: true)
        try assertEqual(db.count, 1, "DB should have 1 row after first create")
        try assertEqual(db[0].content, "smoke alpha", "created content")

        guard let recordX = controller.smokeFirstRecordPriorityMinX else {
            throw SmokeFailure("record cell should exist after first create")
        }
        if let allTitleX = controller.smokeAllTitleMinX {
            try assertClose(recordX, allTitleX + Theme.Size.listTextNudge, "priority text aligns with All text", tolerance: 2)
        }
        if let timeGap = controller.smokeFirstRecordTimeTrailingGap {
            try assertClose(timeGap, 16, "time trailing aligns with the 16pt rail", tolerance: 14)
        }
        if let disclosureX = controller.smokeFirstGroupHeaderDisclosureMinX {
            try assertClose(
                disclosureX + Theme.Size.disclosureSize / 2,
                controller.smokeAddButtonFrame.midX,
                "group chevron centres under the Scope Bar's + chip",
                tolerance: 1
            )
        }
        if controller.smokeHasInboxGroupHeader {
            throw SmokeFailure("creating into All should not grow an Inbox group header")
        }
        if let titleX = controller.smokeFirstGroupHeaderTitleMinX {
            try assertClose(recordX, titleX, "record and group title share the same leading", tolerance: 1)
        }
    }

    /// c. Type "smoke beta" + Return → 2 rows.
    private static func stepC(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
        try typeText("smoke beta", window: window, controller: controller)
        try sendReturn(window: window)
        try waitUntil(showing: "2 visible records after creating 'smoke beta'") {
            controller.smokeVisibleRecords.count == 2
                && controller.smokeInputString.isEmpty
                && controller.smokeIsInputFirstResponder()
        }
        let db = try searchSync(store: store, includeResolved: true)
        try assertEqual(db.count, 2, "DB should have 2 rows after second create")
    }

    /// d. Search "alpha" → 1 row; clear the input → 2 rows again.
    /// Newest-first: visible pair is (beta, alpha).
    private static func stepD(window: NSWindow, controller: MainViewController) throws -> (alphaID: String, betaID: String) {
        try typeText("alpha", window: window, controller: controller)
        try waitUntil(showing: "search 'alpha' filters to 1 record") {
            controller.smokeInputString == "alpha" && controller.smokeVisibleRecords.count == 1
        }
        try assertEqual(controller.smokeVisibleRecords[0].content, "smoke alpha", "filtered record")

        try clearInput(window: window, controller: controller)
        try waitUntil(showing: "cleared search restores 2 records") {
            controller.smokeInputString.isEmpty && controller.smokeVisibleRecords.count == 2
        }

        let visible = controller.smokeVisibleRecords
        guard let beta = visible.first(where: { $0.content == "smoke beta" }),
              let alpha = visible.first(where: { $0.content == "smoke alpha" }) else {
            throw SmokeFailure("expected smoke alpha and smoke beta in the list, got \(visible.map(\.content))")
        }
        return (alphaID: alpha.id, betaID: beta.id)
    }

    /// e. ↓ → table first responder, first record selected; ← → that record is P1.
    private static func stepE(
        window: NSWindow,
        controller: MainViewController,
        store: RecordStore,
        betaID: String
    ) throws {
        controller.focusInputAtEnd()
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "table is first responder with first record selected") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord != nil
        }
        guard let selected = controller.smokeSelectedRecord else {
            throw SmokeFailure("↓ did not select a record")
        }
        try assertEqual(selected.id, betaID, "↓ should select the first (newest) record, smoke beta")

        try sendArrow(.leftArrow, keyCode: KeyCode.leftArrow, window: window)
        try waitUntil(showing: "selected record priority is P1") {
            controller.smokeSelectedRecord?.priority == Priority.p1.rawValue
        }
        guard let db = try store.recordByID(betaID) else {
            throw SmokeFailure("DB missing beta after priority change")
        }
        try assertEqual(db.priority, Priority.p1.rawValue, "DB priority of smoke beta")
    }

    /// f. Space → resolved and gone from the list (Show Resolved off).
    private static func stepF(
        window: NSWindow,
        controller: MainViewController,
        store: RecordStore,
        betaID: String,
        alphaID: String
    ) throws {
        try sendSpecial(keyCode: KeyCode.space, characters: " ", window: window)
        try waitUntil(showing: "resolved record left the list") {
            controller.smokeVisibleRecords.count == 1
                && controller.smokeVisibleRecords.first?.id == alphaID
        }
        guard let db = try store.recordByID(betaID) else {
            throw SmokeFailure("DB missing beta after resolve")
        }
        try assertEqual(db.status, RecordStatus.resolved.rawValue, "beta status after Space")
    }

    /// g. Focus still valid (inheritance); ⌫ trashes remaining; ⌘Z restores.
    private static func stepG(
        window: NSWindow,
        controller: MainViewController,
        store: RecordStore,
        alphaID: String
    ) throws {
        if !controller.smokeIsTableFirstResponder() || controller.smokeSelectedRecord == nil {
            controller.focusInputAtEnd()
            try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        }
        try waitUntil(showing: "focus inherited onto remaining record") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord?.id == alphaID
        }

        try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
        try waitUntil(showing: "remaining record moved to trash") {
            controller.smokeVisibleRecords.isEmpty
        }
        let trashed = try trashedSync(store: store)
        try assertEqual(trashed.count, 1, "trash count")
        try assertEqual(trashed[0].id, alphaID, "trashed record id")

        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z restored the trashed record") {
            controller.smokeVisibleRecords.contains(where: { $0.id == alphaID })
        }
        let stillTrashed = try trashedSync(store: store)
        try assertEqual(stillTrashed.count, 0, "trash empty after undo")
        guard let restored = try store.recordByID(alphaID) else {
            throw SmokeFailure("DB missing alpha after undo")
        }
        try assertEqual(restored.status, RecordStatus.open.rawValue, "restored status")
    }

    /// h. Multi-select: ⇧↓ extends the selection to two records, ⌘C puts
    /// both Contents on the pasteboard (one per line), ⌫ trashes both, ⌘Z
    /// restores both as one undo step, Space resolves both.
    private static func stepH(
        window: NSWindow,
        controller: MainViewController,
        store: RecordStore,
        alphaID: String
    ) throws {
        try typeText("smoke gamma", window: window, controller: controller)
        try sendReturn(window: window)
        try waitUntil(showing: "2 visible records after creating 'smoke gamma'") {
            controller.smokeVisibleRecords.count == 2
        }
        try typeText("smoke delta", window: window, controller: controller)
        try sendReturn(window: window)
        try waitUntil(showing: "3 visible records after creating 'smoke delta'") {
            controller.smokeVisibleRecords.count == 3 && controller.smokeIsInputFirstResponder()
        }

        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "first record selected before ⇧↓") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecords.count == 1
        }
        try sendKey(
            characters: String(NSEvent.SpecialKey.downArrow.unicodeScalar),
            keyCode: KeyCode.downArrow,
            flags: .shift,
            window: window
        )
        try waitUntil(showing: "⇧↓ extended selection to 2 records") {
            controller.smokeSelectedRecords.map(\.content) == ["smoke delta", "smoke gamma"]
        }
        let selectedIDs = controller.smokeSelectedRecords.map(\.id)

        // ⌘C: both Contents, display order, one per line. The general
        // pasteboard is machine-global state — restore it afterwards.
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previousClipboard {
                NSPasteboard.general.setString(previousClipboard, forType: .string)
            }
        }
        try sendCommand("c", keyCode: KeyCode.c, window: window)
        try waitUntil(showing: "⌘C put both records on the pasteboard") {
            NSPasteboard.general.string(forType: .string) == "smoke delta\nsmoke gamma"
        }

        try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
        try waitUntil(showing: "batch ⌫ trashed both selected records") {
            controller.smokeVisibleRecords.count == 1
        }
        try assertEqual(try trashedSync(store: store).count, 2, "trash count after batch delete")

        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z restored both records in one step") {
            controller.smokeVisibleRecords.count == 3
        }
        try assertEqual(try trashedSync(store: store).count, 0, "trash empty after batch undo")
        try waitUntil(showing: "restored records are re-selected") {
            Set(controller.smokeSelectedRecords.map(\.id)) == Set(selectedIDs)
        }

        try sendSpecial(keyCode: KeyCode.space, characters: " ", window: window)
        try waitUntil(showing: "batch Space resolved both selected records") {
            controller.smokeVisibleRecords.count == 1
                && controller.smokeVisibleRecords.first?.id == alphaID
        }
        for id in selectedIDs {
            guard let db = try store.recordByID(id) else {
                throw SmokeFailure("DB missing record \(id) after batch resolve")
            }
            try assertEqual(db.status, RecordStatus.resolved.rawValue, "batch-resolved status")
        }
    }

    /// Long Content wraps and grows the row; ⌫ removes the probe record so
    /// later steps keep the same list.
    private static func stepMultilineRowHeight(
        window: NSWindow,
        controller: MainViewController
    ) throws {
        let longContent = String(repeating: "x", count: 120)
        try typeText(longContent, window: window, controller: controller)
        try sendReturn(window: window)
        try waitUntil(showing: "long record is visible") {
            controller.smokeVisibleRecords.contains(where: { $0.content == longContent })
        }
        guard let longRecord = controller.smokeVisibleRecords.first(where: { $0.content == longContent }) else {
            throw SmokeFailure("long record missing after create")
        }
        try waitUntil(showing: "long record row height > 40pt") {
            guard let height = controller.smokeRowHeight(forRecordID: longRecord.id) else { return false }
            return height > 40
        }

        controller.focusInputAtEnd()
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "long record selected before Inline Edit") {
            controller.smokeSelectedRecord?.id == longRecord.id
        }

        // Inline Edit keeps the wrapped layout: the editor is multi-line and
        // the row re-measures live as text is typed, then Esc restores it.
        guard let heightBeforeEdit = controller.smokeRowHeight(forRecordID: longRecord.id) else {
            throw SmokeFailure("long record row height unavailable before Inline Edit")
        }
        try sendReturn(window: window)
        try waitUntil(showing: "Inline Edit started on long record") {
            controller.smokeIsEditingRecord(id: longRecord.id)
        }
        for character in String(repeating: "y", count: 120) {
            try sendCharacter(character, window: window)
        }
        try waitUntil(showing: "row grows while typing in Inline Edit") {
            guard let height = controller.smokeRowHeight(forRecordID: longRecord.id) else { return false }
            return height > heightBeforeEdit + 10
        }
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "Inline Edit ended after Esc") { !controller.smokeIsEditingRecord(id: longRecord.id) }
        try waitUntil(showing: "Inline Edit cancelled and row height restored") {
            guard !controller.smokeIsEditingRecord(id: longRecord.id),
                  let height = controller.smokeRowHeight(forRecordID: longRecord.id) else { return false }
            return abs(height - heightBeforeEdit) < 1
        }
        try waitUntil(showing: "long record re-selected after Esc") {
            controller.smokeSelectedRecord?.id == longRecord.id && controller.smokeIsTableFirstResponder()
        }
        try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
        try waitUntil(showing: "long record removed from the list") {
            !controller.smokeVisibleRecords.contains(where: { $0.id == longRecord.id })
        }
    }

    // MARK: - Snapshots (--snapshot-dir)

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
    private static func stepSnapshots(
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

        controller.smokeOpenTrash()
        try waitUntil(showing: "Trash surface listing the trashed records") {
            controller.smokeIsShowingTrash && controller.smokeTrashTableIsFirstResponder
                && ((window.firstResponder as? NSTableView)?.numberOfRows ?? 0) >= 2
        }
        try eachVariant { try render("trash-default-\($0)") }
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "main surface back after the Trash snapshots") {
            !controller.smokeIsShowingTrash && controller.smokeIsInputFirstResponder()
        }

        window.appearance = NSAppearance(named: .aqua)
        setSnapshotFrame(window: window, width: 720)
        // Leaving Trash re-runs the search asynchronously; ↓ must not race
        // an empty list.
        try waitUntil(showing: "list reloaded after leaving Trash") { !controller.smokeVisibleRecords.isEmpty }
        controller.focusInputAtEnd()
        try sendArrow(.downArrow, keyCode: KeyCode.downArrow, window: window)
        try waitUntil(showing: "first record selected for the Row Focus snapshot") {
            controller.smokeIsTableFirstResponder() && controller.smokeSelectedRecord != nil
        }
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
    private static var snapshotManifest: [String] = []

    /// Renders the window's content view to `<directory>/<name>.png`.
    /// `wrapRecordID` also logs that row's wrap metrics for the pixel review.
    private static func renderSnapshot(
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
    private static func setSnapshotFrame(window: NSWindow, width: CGFloat) {
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
    private static func seedSnapshotData(controller: MainViewController, store: RecordStore) throws -> String {
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
    private static let snapshotLongContent =
        "把同步冲突处理方案再过一遍：schema v4 加 conflict_of 字段并随 CloudKit 同步，列表里的冲突行在时间列位置显示弱化的 Conflict 标签，"
        + "Utility 栏出现 N conflicts chip，右键菜单提供 Keep This / Keep Other / Keep Both 三个动作；Keep This 把对方移入 Trash，可恢复且无损，"
        + "Keep Both 只清空标记，不新增任何 surface。Review with the team on Thursday and write the numbers into HISTORY."

    // MARK: - Event synthesis

    private static func typeText(_ text: String, window: NSWindow, controller: MainViewController) throws {
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused before typing '\(text)'") {
            controller.smokeIsInputFirstResponder()
        }
        let start = controller.smokeInputString
        for character in text {
            try sendCharacter(character, window: window)
        }
        try waitUntil(showing: "input text is '\(start + text)'") {
            controller.smokeInputString == start + text
        }
    }

    private static func clearInput(window: NSWindow, controller: MainViewController) throws {
        controller.focusInputAtEnd()
        try sendCommand("a", keyCode: KeyCode.a, window: window)
        try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
        if !controller.smokeInputString.isEmpty {
            while !controller.smokeInputString.isEmpty {
                try sendSpecial(keyCode: KeyCode.delete, characters: "\u{7f}", window: window)
                pump()
            }
        }
        try waitUntil(showing: "input cleared") { controller.smokeInputString.isEmpty }
    }

    private static func sendCharacter(_ character: Character, window: NSWindow) throws {
        let string = String(character)
        guard let keyCode = Self.keyCodes[character] else {
            throw SmokeFailure("no keyCode mapping for \(character) (IME/Chinese is not synthesized)")
        }
        try sendKey(characters: string, keyCode: keyCode, window: window)
    }

    private static func sendReturn(window: NSWindow) throws {
        try sendKey(characters: "\r", keyCode: KeyCode.returnKey, window: window)
    }

    private static func sendSpecial(keyCode: UInt16, characters: String = "", window: NSWindow) throws {
        try sendKey(characters: characters, keyCode: keyCode, window: window)
    }

    private static func sendArrow(_ key: NSEvent.SpecialKey, keyCode: UInt16, window: NSWindow) throws {
        let characters = String(key.unicodeScalar)
        try sendKey(characters: characters, keyCode: keyCode, window: window)
        if let textView = window.firstResponder as? NSTextView,
           let event = makeKeyEvent(characters: characters, keyCode: keyCode, flags: [], window: window) {
            // Arrow keys need interpretKeyEvents to become moveDown:/moveLeft:
            // when the window is not key and sendEvent does not convert them.
            textView.interpretKeyEvents([event])
            pump()
        }
    }

    private static func sendCommand(_ character: String, keyCode: UInt16, window: NSWindow) throws {
        // Menu key equivalents with a nil target resolve through the *key*
        // window's responder chain. When the smoke process is not the
        // active app (the usual case from a shell) there is no key window
        // and the action silently goes nowhere, so dispatch straight down
        // the smoke window's responder chain instead.
        if NSApp.keyWindow == nil,
           let item = menuItem(keyEquivalent: character, in: NSApp.mainMenu),
           let action = item.action {
            guard window.firstResponder?.tryToPerform(action, with: item) == true else {
                throw SmokeFailure("⌘\(character) not handled by the responder chain")
            }
            pump()
            return
        }
        guard let event = makeKeyEvent(
            characters: character,
            keyCode: keyCode,
            flags: .command,
            window: window
        ) else {
            throw SmokeFailure("could not synthesize ⌘\(character)")
        }
        // ⌘ shortcuts are matched on the menu, not as keyDown on the view.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            pump()
            return
        }
        if window.performKeyEquivalent(with: event) {
            pump()
            return
        }
        throw SmokeFailure("⌘\(character) was not handled as a key equivalent")
    }

    private static func menuItem(keyEquivalent: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == keyEquivalent, item.keyEquivalentModifierMask == .command {
                return item
            }
            if let found = menuItem(keyEquivalent: keyEquivalent, in: item.submenu) {
                return found
            }
        }
        return nil
    }

    private static func sendKey(
        characters: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) throws {
        window.makeKeyAndOrderFront(nil)
        guard let event = makeKeyEvent(
            characters: characters,
            keyCode: keyCode,
            flags: flags,
            window: window
        ) else {
            throw SmokeFailure("could not synthesize keyCode \(keyCode)")
        }
        NSApp.sendEvent(event)
        pump()
    }

    private static func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: - Store waits

    private static func searchSync(
        store: RecordStore,
        term: String = "",
        includeResolved: Bool
    ) throws -> [Record] {
        var result: Result<[Record], Error>?
        store.search(
            term: term,
            scope: .all,
            token: 0,
            sortOrder: .newestFirst,
            includeResolved: includeResolved
        ) { r, _ in
            result = r
        }
        try waitUntil(showing: "store search completed") { result != nil }
        return try result!.get()
    }

    private static func createRecordSync(store: RecordStore, content: String, projectID: String? = nil) throws -> Record {
        var result: Result<Record, Error>?
        store.createRecord(content: content, projectID: projectID) { result = $0 }
        try waitUntil(showing: "record '\(content.prefix(24))' created") { result != nil }
        return try result!.get()
    }

    private static func applySync(_ label: String, _ write: (@escaping (Result<Void, Error>) -> Void) -> Void) throws {
        var result: Result<Void, Error>?
        write { result = $0 }
        try waitUntil(showing: label) { result != nil }
        try result!.get()
    }

    private static func trashedSync(store: RecordStore) throws -> [Record] {
        var result: Result<[Record], Error>?
        store.listTrashed { result = $0 }
        try waitUntil(showing: "listTrashed completed") { result != nil }
        return try result!.get()
    }

    // MARK: - Run loop

    private static func waitUntil(
        timeout: TimeInterval = 3,
        showing: String,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            pump()
        }
        if !condition() {
            throw SmokeFailure("timeout waiting for \(showing)")
        }
    }

    private static func pump() {
        // Drain default and common so RecordStore's main-async completions run.
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }

    private static func midpoint(_ rect: NSRect?, _ label: String) throws -> NSPoint {
        guard let rect, rect.width > 0, rect.height > 0 else {
            throw SmokeFailure("expected a non-empty frame for \(label) hit-testing, got \(String(describing: rect))")
        }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private static func hitView(in window: NSWindow, at windowPoint: NSPoint) -> NSView? {
        guard let content = window.contentView, let parent = content.superview else { return nil }
        return content.hitTest(parent.convert(windowPoint, from: nil))
    }

    private static func assertHit<T: NSView>(
        _ type: T.Type,
        in window: NSWindow,
        at windowPoint: NSPoint,
        _ label: String
    ) throws {
        let hit = hitView(in: window, at: windowPoint)
        guard hit is T else {
            throw SmokeFailure("\(label): expected \(T.self), got \(String(describing: hit))")
        }
        if hit?.mouseDownCanMoveWindow != false {
            throw SmokeFailure("\(label): hit view must not drag the window")
        }
    }

    /// `ScopeChipButton.mouseDown` tracks with `nextEvent`, so queue the
    /// mouse-up before delivering mouse-down.
    private static func click(at windowPoint: NSPoint, window: NSWindow) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return }
        window.postEvent(up, atStart: false)
        window.sendEvent(down)
        pump()
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        if actual != expected {
            throw SmokeFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private static func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    private static func assertContentSize(
        of window: NSWindow,
        equals expected: NSSize,
        _ label: String,
        tolerance: CGFloat = 1
    ) throws {
        let actual = contentSize(of: window)
        if abs(actual.width - expected.width) > tolerance
            || abs(actual.height - expected.height) > tolerance {
            throw SmokeFailure("\(label): expected \(expected) ±\(tolerance), got \(actual)")
        }
    }

    private static func assertClose(_ actual: CGFloat, _ expected: CGFloat, _ label: String, tolerance: CGFloat = 1) throws {
        if abs(actual - expected) > tolerance {
            throw SmokeFailure("\(label): expected \(expected) ±\(tolerance), got \(actual)")
        }
    }

    private static func writeLine(_ string: String) {
        FileHandle.standardOutput.write(Data((string + "\n").utf8))
        fflush(stdout)
    }

    /// US-layout virtual key codes used by the ASCII smoke string.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49
    ]

    private enum KeyCode {
        static let a: UInt16 = 0
        static let c: UInt16 = 8
        static let z: UInt16 = 6
        static let comma: UInt16 = 43
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let leftArrow: UInt16 = 123
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
