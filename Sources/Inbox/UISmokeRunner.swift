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
            try stepA(window: window, controller: controller)
            try stepB(window: window, controller: controller, store: store)
            try stepC(window: window, controller: controller, store: store)
            let pair = try stepD(window: window, controller: controller)
            try stepE(window: window, controller: controller, store: store, betaID: pair.betaID)
            try stepF(window: window, controller: controller, store: store, betaID: pair.betaID, alphaID: pair.alphaID)
            try stepG(window: window, controller: controller, store: store, alphaID: pair.alphaID)
            writeLine("UI-SMOKE PASS")
            exit(0)
        } catch {
            writeLine("UI-SMOKE FAIL: \(error)")
            exit(1)
        }
    }

    // MARK: - Steps

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

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        if actual != expected {
            throw SmokeFailure("\(label): expected \(expected), got \(actual)")
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
        static let z: UInt16 = 6
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let leftArrow: UInt16 = 123
        static let downArrow: UInt16 = 125
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
