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
            try stepScopeBarOverflow()
            try stepA(window: window, controller: controller)
            try stepB(window: window, controller: controller, store: store)
            try stepC(window: window, controller: controller, store: store)
            let pair = try stepD(window: window, controller: controller)
            try stepE(window: window, controller: controller, store: store, betaID: pair.betaID)
            try stepF(window: window, controller: controller, store: store, betaID: pair.betaID, alphaID: pair.alphaID)
            try stepG(window: window, controller: controller, store: store, alphaID: pair.alphaID)
            try stepH(window: window, controller: controller, store: store, alphaID: pair.alphaID)
            try stepMultilineRowHeight(window: window, controller: controller)
            try stepWindowReopen(window: window, controller: controller)
            try stepSettings(window: window)
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
            equals: MainWindowGeometry.defaultContentSize,
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
        if window.frame.width < MainWindowGeometry.minimumSize.width {
            throw SmokeFailure(
                "minSize should clamp width >= \(MainWindowGeometry.minimumSize.width), got \(window.frame.width)"
            )
        }

        window.setFrame(originalFrame, display: true)
        window.layoutIfNeeded()
        pump()
        try assertContentSize(
            of: window,
            equals: MainWindowGeometry.defaultContentSize,
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
        try assertClose(input.height, UniversalInputView.chromeHeight, "input chrome height")
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
        let listGap = controller.smokeListTopGap
        if listGap < 6 || listGap > 12 {
            throw SmokeFailure("scope bar should sit with similar air above the list as above the chips, gap=\(listGap)")
        }
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
                  let strokeRGB = ChipChrome.outlineColor.usingColorSpace(.deviceRGB) else { return }
            borderRGB.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            strokeRGB.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
            strokeConverted = true
        }
        if !strokeConverted {
            throw SmokeFailure("idle chip stroke color could not be resolved")
        }
        if abs(br - sr) > 0.08 || abs(bg - sg) > 0.08 || abs(bb - sb) > 0.08 || abs(ba - sa) > 0.08 {
            throw SmokeFailure(
                "idle chip stroke should match tertiaryLabelColor, got (\(br), \(bg), \(bb), \(ba))"
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
                  let labelRGB = NSColor.labelColor.usingColorSpace(.sRGB) else { return }
            selectedRGB.getRed(&r, green: &g, blue: &b, alpha: &a)
            labelRGB.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
            converted = true
        }
        if !converted {
            throw SmokeFailure("selected scope chip title color could not be resolved")
        }
        if abs(r - lr) > 0.15 || abs(g - lg) > 0.15 || abs(b - lb) > 0.15 {
            throw SmokeFailure("selected scope chip text should use labelColor, got \(selectedColor)")
        }
        guard let selectedFill = controller.smokeSelectedScopeChipFillColor else {
            throw SmokeFailure("selected scope chip should have a fill color")
        }
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        var fillConverted = false
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let fillRGB = NSColor(cgColor: selectedFill)?.usingColorSpace(.deviceRGB),
                  let controlRGB = ChipChrome.selectedFill.usingColorSpace(.deviceRGB) else { return }
            fillRGB.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            controlRGB.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            fillConverted = true
        }
        if !fillConverted {
            throw SmokeFailure("selected scope chip fill color could not be resolved")
        }
        if abs(fr - cr) > 0.08 || abs(fg - cg) > 0.08 || abs(fb - cb) > 0.08 || abs(fa - ca) > 0.08 {
            throw SmokeFailure(
                "selected scope chip fill should match controlBackgroundColor, got (\(fr), \(fg), \(fb), \(fa))"
            )
        }
        if controller.smokeHasInboxGroupHeader {
            throw SmokeFailure("All view should not show an Inbox group header")
        }
        if let titleX = controller.smokeFirstGroupHeaderTitleMinX {
            if let allTitleX = controller.smokeAllTitleMinX {
                try assertClose(titleX, allTitleX + LayoutChrome.listTextNudge, "group title aligns with All text", tolerance: 2)
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
            equals: MainWindowGeometry.defaultContentSize,
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
            equals: MainWindowGeometry.defaultContentSize,
            "content size after close and presentMainWindow"
        )
        try waitUntil(showing: "Universal Input is first responder after reopen") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
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
            try assertClose(recordX, allTitleX + LayoutChrome.listTextNudge, "priority text aligns with All text", tolerance: 2)
        }
        if let timeGap = controller.smokeFirstRecordTimeTrailingGap {
            try assertClose(timeGap, 16, "time trailing aligns with the 16pt rail", tolerance: 14)
        }
        if let timeGap = controller.smokeFirstRecordTimeTrailingGap,
           let disclosureGap = controller.smokeFirstGroupDisclosureTrailingGap {
            try assertClose(timeGap, disclosureGap, "time and disclosure share the trailing rail", tolerance: 2)
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

        try sendSpecial(keyCode: KeyCode.leftArrow, window: window)
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
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
