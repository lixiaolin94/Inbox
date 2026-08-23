#if DEBUG
import AppKit

/// Interaction steps: the Create → Search → Priority → Resolve → Inline
/// Edit → Delete → Undo chain, conflicts, Trash, Settings, window reopen.
extension UISmokeRunner {
    /// Bottom bar: the three chips are `ScopeChipButton`s on the chip rails
    /// (the custom chip is kept here on purpose — see MainViewController),
    /// Resolved toggles state without moving first responder, the sort
    /// chip's face and menu stay in sync and a pick re-orders the list.
    /// Double-click on a row opens Inline Edit with the caret at the click
    /// — aim between "smoke " and "alpha" and expect the caret there;
    /// Esc leaves the text untouched and Row Focus on the row.
    static func stepDoubleClickEdit(window: NSWindow, controller: MainViewController) throws {
        guard let record = controller.smokeVisibleRecords.first(where: { $0.content == "smoke alpha" }) else {
            throw SmokeFailure("'smoke alpha' should be listed before the double-click probe")
        }
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused before the double-click") { controller.smokeIsInputFirstResponder() }
        guard let origin = controller.smokeContentTextOrigin(forRecordID: record.id) else {
            throw SmokeFailure("content text origin for the double-click probe")
        }
        let prefix = ("smoke " as NSString).size(withAttributes: [.font: Theme.Typography.row]).width
        let point = NSPoint(x: origin.x + prefix, y: origin.y)
        // AppKit's own click counting is not exercised: a synthesized
        // double-click through NSTableView's tracking loop is timing
        // dependent. The wiring is asserted, the handler driven directly.
        if !controller.smokeDoubleActionWired {
            throw SmokeFailure("table doubleAction should open Inline Edit")
        }
        controller.smokeDoubleClick(at: point)
        try waitUntil(showing: "double-click began Inline Edit") { controller.smokeIsEditingRecord(id: record.id) }
        guard let caret = controller.smokeCaretLocation(forRecordID: record.id) else {
            throw SmokeFailure("caret location while editing after a double-click")
        }
        if abs(caret - 6) > 1 {
            throw SmokeFailure("caret should land near the click (between 'smoke ' and 'alpha', index 6), got \(caret)")
        }
        try sendSpecial(keyCode: KeyCode.escape, characters: "\u{1b}", window: window)
        try waitUntil(showing: "Esc ended the double-click edit") {
            !controller.smokeIsEditingRecord(id: record.id) && controller.smokeIsTableFirstResponder()
                && controller.smokeSelectedRecord?.id == record.id
        }
        try assertEqual(controller.smokeVisibleRecords.first { $0.id == record.id }?.content, "smoke alpha", "content untouched after Esc")
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused after the double-click probe") { controller.smokeIsInputFirstResponder() }
    }

    /// Right-click ▸ Mark as Resolved: the row's menu offers the
    /// status flip, it resolves like Space does, ⌘Z reopens, and a resolved
    /// row's menu says Reopen.
    static func stepContextMenuResolve(window: NSWindow, controller: MainViewController) throws {
        guard let record = controller.smokeVisibleRecords.first(where: { $0.content == "smoke alpha" }) else {
            throw SmokeFailure("'smoke alpha' should be listed before the context-menu probe")
        }
        try assertEqual(
            controller.smokeContextMenuTitles(forRecordID: record.id),
            ["Mark as Resolved", "Move to", "", "Move to Trash"],
            "record context menu"
        )
        if !controller.smokePerformContextMenuItem("Mark as Resolved", forRecordID: record.id) {
            throw SmokeFailure("Mark as Resolved missing from the context menu")
        }
        try waitUntil(showing: "menu resolved the record (hidden while Show Resolved is off)") {
            !controller.smokeVisibleRecords.contains { $0.id == record.id }
        }
        controller.smokeClickResolved()
        try waitUntil(showing: "resolved record listed again") {
            controller.smokeVisibleRecords.first { $0.id == record.id }?.status == RecordStatus.resolved.rawValue
        }
        try assertEqual(controller.smokeContextMenuTitles(forRecordID: record.id)?.first, "Reopen", "resolved row offers Reopen")
        controller.smokeClickResolved()
        try waitUntil(showing: "Show Resolved off again") { !Preferences.showResolved }
        try sendCommand("z", keyCode: KeyCode.z, window: window)
        try waitUntil(showing: "⌘Z reopened the record resolved from the menu") {
            controller.smokeVisibleRecords.first { $0.id == record.id }?.status == RecordStatus.open.rawValue
        }
        controller.focusInputAtEnd()
        try waitUntil(showing: "input focused after the context-menu probe") { controller.smokeIsInputFirstResponder() }
    }

    /// Conflict centre (PRD §15.3): a pair manufactured straight in the DB
    /// badges both rows and raises the utility-bar chip; the chip narrows
    /// the list to the pair without moving first responder; Keep This from
    /// the duplicate's context menu trashes the original and settles the
    /// pair. Leaves the list as it found it (alpha, beta; Trash empty) by
    /// restoring the original and resolving both probe records away.
    static func stepConflicts(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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
        try assertClose(
            chipFrame.midY,
            controller.smokeUtilityControlFrame(controller.smokeSortChip).midY,
            "conflicts chip on the function group's centre line"
        )
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
            Array(controller.smokeContextMenuTitles(forRecordID: duplicate.id)?.prefix(3) ?? []),
            ["Resolve Conflict", "Mark as Resolved", "Move to"],
            "Resolve Conflict sits above the status item and Move to on a conflicted row"
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
        try assertEqual(controller.smokeContextMenuTitles(forRecordID: duplicate.id)?.first, "Mark as Resolved", "no Resolve Conflict item once settled")
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
    static func stepUndoResolveAndMove(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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
    static func stepTrashSurface(window: NSWindow, controller: MainViewController) throws {
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
    static func stepSettings(window: NSWindow) throws {
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
    static func stepWindowReopen(window: NSWindow, controller: MainViewController) throws {
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
    static func stepA(window: NSWindow, controller: MainViewController) throws {
        controller.focusInputAtEnd()
        try waitUntil(showing: "Universal Input is first responder (field editor)") {
            controller.smokeIsInputFirstResponder() && window.firstResponder is NSTextView
        }
    }

    /// b. Type "smoke alpha" + Return → 1 row, DB has 1, Input cleared and focused.
    static func stepB(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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
        // The list's text rail is its own token (`contentInset`-based); it
        // coincides with All's letters only while contentInset == windowInset.
        try assertClose(recordX, Theme.Size.textRail, "priority text on the list text rail", tolerance: 2)
        if Theme.Size.contentInset == Theme.Size.windowInset, let allTitleX = controller.smokeAllTitleMinX {
            try assertClose(recordX, allTitleX + Theme.Size.listTextNudge, "priority text aligns with All text", tolerance: 2)
        }
        if let timeGap = controller.smokeFirstRecordTimeTrailingGap {
            try assertClose(timeGap, Theme.Size.timeRail, "time column ends on the right text rail (under the + glyph)", tolerance: 0.5)
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
    static func stepC(window: NSWindow, controller: MainViewController, store: RecordStore) throws {
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
    static func stepD(window: NSWindow, controller: MainViewController) throws -> (alphaID: String, betaID: String) {
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
    static func stepE(
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
    static func stepF(
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
    static func stepG(
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
    static func stepH(
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
    static func stepMultilineRowHeight(
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
}
#endif
