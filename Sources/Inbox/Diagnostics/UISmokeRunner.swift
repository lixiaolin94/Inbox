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

    static func run(window: NSWindow, controller: MainViewController, store: RecordStore) {
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
            try stepDoubleClickEdit(window: window, controller: controller)
            try stepContextMenuResolve(window: window, controller: controller)
            try stepOpticalRails(window: window, controller: controller, store: store)
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
            try stepGlobalSummon()
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

    // MARK: - Event synthesis

    static func typeText(_ text: String, window: NSWindow, controller: MainViewController) throws {
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

    static func clearInput(window: NSWindow, controller: MainViewController) throws {
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

    static func sendCharacter(_ character: Character, window: NSWindow) throws {
        let string = String(character)
        guard let keyCode = Self.keyCodes[character] else {
            throw SmokeFailure("no keyCode mapping for \(character) (IME/Chinese is not synthesized)")
        }
        try sendKey(characters: string, keyCode: keyCode, window: window)
    }

    static func sendReturn(window: NSWindow) throws {
        try sendKey(characters: "\r", keyCode: KeyCode.returnKey, window: window)
    }

    static func sendSpecial(keyCode: UInt16, characters: String = "", window: NSWindow) throws {
        try sendKey(characters: characters, keyCode: keyCode, window: window)
    }

    static func sendArrow(_ key: NSEvent.SpecialKey, keyCode: UInt16, window: NSWindow) throws {
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

    static func sendCommand(_ character: String, keyCode: UInt16, window: NSWindow) throws {
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

    static func menuItem(keyEquivalent: String, in menu: NSMenu?) -> NSMenuItem? {
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

    static func sendKey(
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

    static func makeKeyEvent(
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

    static func searchSync(
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

    static func createRecordSync(store: RecordStore, content: String, projectID: String? = nil) throws -> Record {
        var result: Result<Record, Error>?
        store.createRecord(content: content, projectID: projectID) { result = $0 }
        try waitUntil(showing: "record '\(content.prefix(24))' created") { result != nil }
        return try result!.get()
    }

    static func applySync(_ label: String, _ write: (@escaping (Result<Void, Error>) -> Void) -> Void) throws {
        var result: Result<Void, Error>?
        write { result = $0 }
        try waitUntil(showing: label) { result != nil }
        try result!.get()
    }

    static func trashedSync(store: RecordStore) throws -> [Record] {
        var result: Result<[Record], Error>?
        store.listTrashed { result = $0 }
        try waitUntil(showing: "listTrashed completed") { result != nil }
        return try result!.get()
    }

    // MARK: - Run loop

    static func waitUntil(
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

    static func pump() {
        // Drain default and common so RecordStore's main-async completions run.
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }

    static func midpoint(_ rect: NSRect?, _ label: String) throws -> NSPoint {
        guard let rect, rect.width > 0, rect.height > 0 else {
            throw SmokeFailure("expected a non-empty frame for \(label) hit-testing, got \(String(describing: rect))")
        }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    static func hitView(in window: NSWindow, at windowPoint: NSPoint) -> NSView? {
        guard let content = window.contentView, let parent = content.superview else { return nil }
        return content.hitTest(parent.convert(windowPoint, from: nil))
    }

    static func assertHit<T: NSView>(
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
    static func click(at windowPoint: NSPoint, window: NSWindow) {
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

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        if actual != expected {
            throw SmokeFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    static func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    static func assertContentSize(
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

    static func assertClose(_ actual: CGFloat, _ expected: CGFloat, _ label: String, tolerance: CGFloat = 1) throws {
        if abs(actual - expected) > tolerance {
            throw SmokeFailure("\(label): expected \(expected) ±\(tolerance), got \(actual)")
        }
    }

    static func writeLine(_ string: String) {
        FileHandle.standardOutput.write(Data((string + "\n").utf8))
        fflush(stdout)
    }

    /// US-layout virtual key codes used by the ASCII smoke string.
    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49
    ]

    enum KeyCode {
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

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
