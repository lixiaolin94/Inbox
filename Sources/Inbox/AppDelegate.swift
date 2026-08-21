import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainViewController: MainViewController!
    private var recordStore: RecordStore!
    private var syncEngine: InboxSyncEngine?
    private var statusItem: NSStatusItem?
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

        syncEngine = InboxSyncEngine.makeIfEnabled(
            store: recordStore,
            stateURL: InboxSyncEngine.stateURL(databasePath: launch.databasePath),
            launch: launch
        )

        if launch.syncProbe != nil {
            NSApp.setActivationPolicy(.accessory)
            SyncProbeRunner.start(store: recordStore, engine: syncEngine, configuration: launch)
            return
        }

        mainViewController = MainViewController(store: recordStore)
        mainViewController.onProjectsChanged = { [weak self] projects in
            self?.rebuildGoMenuProjectItems(projects: projects)
        }

        buildMainMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Inbox"
        window.minSize = NSSize(width: 480, height: 320)
        window.contentViewController = mainViewController
        window.delegate = self
        // Hide-on-close: the same NSWindow is reused for Dock, ⌘Tab, and
        // menu-bar Open Inbox. `windowShouldClose` orders it out and
        // returns false so AppKit never releases it; this flag is the
        // belt if something still sends `close`.
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        installStatusItem()
        NSApp.activate(ignoringOtherApps: true)

        if launch.isUISmoke {
            UISmokeRunner.start(window: window, controller: mainViewController, store: recordStore)
        }
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

    /// Single reopen path used by Dock, ⌘Tab, and the menu-bar item.
    @objc func presentMainWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        mainViewController.focusInputAtEnd()
    }

    // MARK: - Menu bar (PRD §13.3)

    /// Template status item. The menu is built once; Launch at Login state
    /// is refreshed in `validateMenuItem` when the menu opens — no timer.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Inbox")
            button.image?.isTemplate = true
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
        item.menu = menu
        statusItem = item
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
    /// App (Close ⌘W, Quit ⌘Q), Edit (standard text-editing selectors so
    /// Cut/Copy/Paste/Undo work in Universal Input and Inline Edit), and Go
    /// (Scope switching, PRD §9).
    private func buildMainMenu() {
        let mainMenu = NSMenu(title: "Inbox")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = buildAppMenu()

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

    /// Cmd+W / the red traffic light hide the window instead of destroying
    /// it, so the process stays resident for menu-bar / Dock reopen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
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
