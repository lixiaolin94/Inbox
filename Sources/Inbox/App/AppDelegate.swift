import AppKit
import CloudKit
import ServiceManagement

/// Applies `minSize`/`maxSize` to `setFrame` as well as live user resize.
/// Stock `NSWindow.constrainFrameRect` only keeps the frame on-screen.
private final class InboxWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var frame = super.constrainFrameRect(frameRect, to: screen)
        frame.size.width = min(max(frame.size.width, minSize.width), maxSize.width)
        frame.size.height = min(max(frame.size.height, minSize.height), maxSize.height)
        return frame
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainViewController: MainViewController!
    private var recordStore: RecordStore!
    private var syncEngine: InboxSyncEngine?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: SettingsWindowController?
    private var launch = LaunchConfiguration.parse([])

    /// The dynamic Project section of the Go menu (PRD §9): rebuilt whenever
    /// the Project list changes, so `⌘2…⌘0` always tracks Manual Order.
    private let goMenu = NSMenu(title: "Go")
    /// Fixed items that stay put while `goMenu`'s Project section is rebuilt.
    private var goMenuAllItem: NSMenuItem!

    /// The 9 key equivalents for Projects #1–#9 in Manual Order, in order:
    /// `⌘2` through `⌘9`, then `⌘0` (PRD §9).
    private static let projectKeyEquivalents = ["2", "3", "4", "5", "6", "7", "8", "9", "0"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        launch = LaunchConfiguration.parse(CommandLine.arguments)
        Preferences.configure(suiteName: launch.defaultsSuiteName)

        NSApp.setActivationPolicy(.regular)

        do {
            if let databasePath = launch.databasePath {
                recordStore = try RecordStore(databasePath: databasePath)
            } else {
                recordStore = try RecordStore()
            }
        } catch {
            // Local storage is required for the app to function at all —
            // this is not a recoverable error.
            fatalError("Failed to open local database: \(error)")
        }

        #if DEBUG
        if launch.syncProbe != nil {
            NSApp.setActivationPolicy(.accessory)
            startSyncEngine()
            SyncProbeRunner.start(store: recordStore, engine: syncEngine, configuration: launch)
            return
        }
        #endif

        mainViewController = MainViewController(store: recordStore)
        mainViewController.onProjectsChanged = { [weak self] projects in
            self?.rebuildGoMenuProjectItems(projects: projects)
        }

        buildMainMenu()

        let window = InboxWindow(
            contentRect: NSRect(origin: .zero, size: Theme.Size.windowDefault),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Inbox"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.minSize = Theme.Size.windowMinimum
        window.contentViewController = mainViewController
        // `contentViewController` assignment sizes the window to the VC's
        // `preferredContentSize` if non-zero, otherwise Auto Layout
        // fittingSize. FittingSize here is ~28pt wide (input padding; no
        // width constraint). `preferredContentSize` would give 720×480 but
        // then AppKit treats that as a hard size and rejects later
        // setFrame / user-resize. `minSize` also does not stop the fitting
        // pass. After mount, set the content size explicitly and center on
        // that frame. Surfaces fill the content view via autoresizing so
        // the window is not an Auto Layout window (which would snap back
        // to fittingSize).
        window.setContentSize(Theme.Size.windowDefault)
        window.delegate = self
        // Hide-on-close: the same NSWindow is reused for Dock, ⌘Tab, and
        // menu-bar Open Inbox. `windowShouldClose` orders it out and
        // returns false so AppKit never releases it; this flag is the
        // belt if something still sends `close`.
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        TitlebarBackdrop.hideSystemFill(in: window)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateGlobalSummon),
            name: .inboxGlobalSummonDidChange,
            object: nil
        )
        updateGlobalSummon()

        // Off the first-frame path: the CloudKit engine (~36 ms) and the
        // status item (~6 ms) are not needed to show the window. A fixed
        // short delay is simpler and more predictable than hooking the
        // first CA commit. Writes made before the engine exists are already
        // recorded as pending in the store and `InboxSyncEngine.init`
        // replays them, so nothing is lost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.startSyncEngine()
            self.refreshOfflineNotice()
            self.installStatusItem()
        }

        #if DEBUG
        if launch.isUISmoke {
            UISmokeRunner.start(window: window, controller: mainViewController, store: recordStore)
        }
        #endif
    }

    private func startSyncEngine() {
        syncEngine = InboxSyncEngine.makeIfEnabled(
            store: recordStore,
            stateURL: InboxSyncEngine.stateURL(databasePath: launch.databasePath),
            launch: launch
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click while the app is already running (window visible or not).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow()
        return false
    }

    /// ⌘Tab / Raycast / Dock activation: show the window if it was closed
    /// and put the caret in Universal Input so the first key is not lost
    /// (PRD §6.2, §13.2, §17.1).
    func applicationDidBecomeActive(_ notification: Notification) {
        // Smoke drives its own focus; stealing Input on activation would
        // break Row Focus steps (↓ / ← / Space / ⌫).
        guard window != nil, !launch.isUISmoke else { return }
        presentMainWindow()
    }

    /// Single reopen path used by Dock, ⌘Tab, the menu-bar item and ⌥Space.
    @objc func presentMainWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        mainViewController.focusInputAtEnd()
    }

    // MARK: - Global summon (⌥Space)

    /// Registration follows the Settings checkbox live — no relaunch.
    @objc private func updateGlobalSummon() {
        if Preferences.isGlobalSummonEnabled {
            GlobalHotKey.register { [weak self] in self?.toggleFromGlobalSummon() }
        } else {
            GlobalHotKey.unregister()
        }
    }

    /// Summon from anywhere; pressed again while Inbox is frontmost it
    /// hides the app, handing focus back to the previous one.
    private func toggleFromGlobalSummon() {
        if NSApp.isActive, window?.isKeyWindow == true {
            NSApp.hide(nil)
        } else {
            presentMainWindow()
        }
    }

    // MARK: - Menu bar (PRD §13.3)

    /// Template status item. Left click opens the main window; right click
    /// shows the menu (attached only for the duration of the popup, since a
    /// permanent `item.menu` would swallow left clicks too). Launch at Login
    /// state is refreshed in `validateMenuItem` when the menu opens — no timer.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "Inbox")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Inbox", action: #selector(presentMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let item = statusItem, let menu = statusMenu {
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else {
            presentMainWindow()
        }
    }

    /// SMAppService only applies to a bundled .app. A SPM-built naked
    /// binary has no bundle identifier, so the item is disabled there.
    private var canManageLaunchAtLogin: Bool {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            return false
        }
        return true
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard canManageLaunchAtLogin else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Main menu

    /// The minimal menu bar this app needs to function without a nib:
    /// App (Close ⌘W, Quit ⌘Q), File (export, PRD §16.1), Edit (standard
    /// text-editing selectors so Cut/Copy/Paste/Undo work in Universal
    /// Input and Inline Edit), and Go (Scope switching, PRD §9).
    private func buildMainMenu() {
        let mainMenu = NSMenu(title: "Inbox")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = buildAppMenu()

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        fileMenuItem.submenu = buildFileMenu()

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = buildEditMenu()

        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        goMenuItem.submenu = buildGoMenu()

        NSApp.mainMenu = mainMenu
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu(title: "Inbox")
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Inbox",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
            settingsWindowController?.window?.center()
        }
        settingsWindowController?.showWindow(self)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    func smokeSettingsWindowVisible() -> Bool {
        settingsWindowController?.window?.isVisible == true
    }

    func smokeCloseSettings() {
        settingsWindowController?.window?.orderOut(nil)
    }
    #endif

    // MARK: - File menu (PRD §16.1)

    private func buildFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        let json = menu.addItem(withTitle: "Export as JSON…", action: #selector(exportJSON(_:)), keyEquivalent: "e")
        json.keyEquivalentModifierMask = [.command, .shift]
        json.target = self
        let snapshot = menu.addItem(
            withTitle: "Export Database Snapshot…",
            action: #selector(exportSnapshot(_:)),
            keyEquivalent: ""
        )
        snapshot.target = self
        menu.addItem(.separator())
        let reveal = menu.addItem(withTitle: "Show Data in Finder", action: #selector(showDataInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        return menu
    }

    /// `Inbox-<yyyy-MM-dd>.<ext>`, the date in the user's calendar day.
    private static func exportFileName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Inbox-\(formatter.string(from: Date())).\(ext)"
    }

    @objc private func exportJSON(_ sender: Any?) {
        guard let recordStore, let mainViewController else { return }
        guard let url = Dialogs.saveExport(suggestedName: Self.exportFileName(extension: "json"), allowedExtension: "json") else {
            mainViewController.focusInputAtEnd()
            return
        }
        // Both reads are enqueued back to back on the serial DB queue, so no
        // write can land between them and their completions arrive on main
        // in this order (ARCHITECTURE §4) — the pair is a consistent snapshot.
        var projects: Result<[Project], Error> = .success([])
        recordStore.projects.listProjects { projects = $0 }
        recordStore.listAllRecordsForExport { records in
            do {
                let document = InboxExport.Document(
                    projects: try projects.get(),
                    records: try records.get(),
                    schemaVersion: try recordStore.currentSchemaVersion()
                )
                try InboxExport.encode(document).write(to: url, options: .atomic)
            } catch {
                Dialogs.persistenceFailure(error)
            }
            mainViewController.focusInputAtEnd()
        }
    }

    @objc private func exportSnapshot(_ sender: Any?) {
        guard let recordStore, let mainViewController else { return }
        guard let url = Dialogs.saveExport(suggestedName: Self.exportFileName(extension: "sqlite"), allowedExtension: "sqlite") else {
            mainViewController.focusInputAtEnd()
            return
        }
        recordStore.writeSnapshot(to: url) { result in
            if case .failure(let error) = result {
                Dialogs.persistenceFailure(error)
            }
            mainViewController.focusInputAtEnd()
        }
    }

    @objc private func showDataInFinder(_ sender: Any?) {
        guard let recordStore, let mainViewController else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recordStore.databasePath)])
        mainViewController.focusInputAtEnd()
    }

    /// Engine-off (user switch / no entitlement / smoke) stays silent.
    /// Engine-on with a non-available account shows the utility-bar label.
    private func refreshOfflineNotice() {
        guard let syncEngine, let controller = mainViewController else { return }
        Task {
            let status = await syncEngine.accountStatus()
            guard status != .available else { return }
            await MainActor.run {
                controller.showOfflineNotice(true)
            }
        }
    }

    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Cut/Copy/Paste/Select All route through the NSText informal
        // protocol. Undo/Redo are owned here so an empty field editor does
        // not swallow Move-to-Trash undo after focus returns to Input.
        let undo = menu.addItem(withTitle: "Undo", action: #selector(undoAction(_:)), keyEquivalent: "z")
        undo.target = self
        let redo = menu.addItem(withTitle: "Redo", action: #selector(redoAction(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func buildGoMenu() -> NSMenu {
        // Leaving `autoenablesItems` at its default `true` is what makes
        // AppKit call `validateMenuItem(_:)` below each time the menu opens
        // — that's how the current-Scope checkmark stays live.
        let allItem = NSMenuItem(title: "All", action: #selector(selectScopeAll), keyEquivalent: "1")
        allItem.target = self
        goMenu.addItem(allItem)
        goMenuAllItem = allItem

        goMenu.addItem(NSMenuItem.separator())
        return goMenu
    }

    /// Replaces everything after the "All" item + separator with one item
    /// per Project, in Manual Order, mapped to `⌘2…⌘0` (PRD §7.4, §9).
    /// Projects past the 9th are reachable only via the Scope Bar / All View
    /// — no menu item, per PRD §9 ("超过九个 Project 的部分通过 Scope Bar 滚动和鼠标选择").
    private func rebuildGoMenuProjectItems(projects: [Project]) {
        while goMenu.items.count > 2 {
            goMenu.removeItem(at: goMenu.items.count - 1)
        }
        for (index, project) in projects.prefix(Self.projectKeyEquivalents.count).enumerated() {
            let item = NSMenuItem(
                title: project.name,
                action: #selector(selectScopeProject(_:)),
                keyEquivalent: Self.projectKeyEquivalents[index]
            )
            item.target = self
            item.representedObject = project.id
            goMenu.addItem(item)
        }
    }

    @objc private func selectScopeAll() {
        mainViewController.switchScope(.all)
    }

    /// Prefer the field editor's typing undo when it has something to undo;
    /// otherwise undo Move to Trash (window stack). This is what makes ⌘Z
    /// restore a Record after deleting the last row, which returns focus
    /// to Universal Input.
    @objc private func undoAction(_ sender: Any?) {
        if let textView = window.firstResponder as? NSTextView,
           textView.undoManager?.canUndo == true {
            textView.undoManager?.undo()
            return
        }
        mainViewController.undoManager?.undo()
    }

    @objc private func redoAction(_ sender: Any?) {
        if let textView = window.firstResponder as? NSTextView,
           textView.undoManager?.canRedo == true {
            textView.undoManager?.redo()
            return
        }
        mainViewController.undoManager?.redo()
    }

    @objc private func selectScopeProject(_ sender: NSMenuItem) {
        guard let projectID = sender.representedObject as? String else { return }
        mainViewController.switchScope(.project(id: projectID))
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Same stack MainViewController.undoManager exposes, so window-level
    /// Undo/Redo (and TrashViewController's default undoManager, which
    /// reads the window) hit Move to Trash rather than a second empty stack.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        mainViewController.undoManager
    }

    func windowDidBecomeMain(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            TitlebarBackdrop.hideSystemFill(in: window)
        }
    }

    /// Cmd+W / the red traffic light hide the window instead of destroying
    /// it, so the process stays resident for menu-bar / Dock reopen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// Tahoe/27 still paints a titlebar material even with
/// `titlebarAppearsTransparent`, which covers the window's sidebar blur.
/// Hide those fills (not the traffic lights) so the content material
/// shows through the titlebar.
///
/// Re-checked 2026-08-22 on macOS 26.6: with the call disabled the probe
/// finds no visible fill, so here it is a no-op; kept because it was
/// added for 27 and costs microseconds. `visibleSystemFills` + the smoke
/// assertion are the re-check mechanism on each new system.
enum TitlebarBackdrop {
    static func hideSystemFill(in window: NSWindow) {
        forEachSystemFill(in: window) { $0.isHidden = true }
    }

    /// Material views still showing in the titlebar — the smoke asserts
    /// this is empty, which is also how the workaround gets re-checked on
    /// each new system: disable the call, run the smoke.
    static func visibleSystemFills(in window: NSWindow) -> [String] {
        var names: [String] = []
        forEachSystemFill(in: window) { view in
            if !view.isHidden { names.append(NSStringFromClass(type(of: view))) }
        }
        return names
    }

    private static func forEachSystemFill(in window: NSWindow, _ body: (NSView) -> Void) {
        guard let closeButton = window.standardWindowButton(.closeButton) else { return }
        var cursor: NSView? = closeButton.superview
        var hops = 0
        while let view = cursor, hops < 5 {
            for subview in view.subviews {
                if subview === window.contentView || subview is NSButton { continue }
                if subview is NSVisualEffectView {
                    body(subview)
                    continue
                }
                if #available(macOS 26.0, *), subview is NSGlassEffectView {
                    body(subview)
                }
            }
            let name = NSStringFromClass(type(of: view))
            cursor = view.superview
            hops += 1
            if name.contains("TitlebarContainer") { break }
        }
    }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    /// Checkmarks the Go menu item matching the current Scope. Edit menu
    /// items are left to AppKit's normal responder-chain validation.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            guard canManageLaunchAtLogin else {
                menuItem.state = .off
                return false
            }
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(undoAction(_:)) {
            let typing = (window.firstResponder as? NSTextView)?.undoManager?.canUndo == true
            let trash = mainViewController.undoManager?.canUndo == true
            return typing || trash
        }
        if menuItem.action == #selector(redoAction(_:)) {
            let typing = (window.firstResponder as? NSTextView)?.undoManager?.canRedo == true
            let trash = mainViewController.undoManager?.canRedo == true
            return typing || trash
        }
        guard menuItem.menu === goMenu else { return true }
        let itemScope: Scope = (menuItem.representedObject as? String).map(Scope.project(id:)) ?? .all
        menuItem.state = itemScope == mainViewController.currentScope ? .on : .off
        return true
    }
}
