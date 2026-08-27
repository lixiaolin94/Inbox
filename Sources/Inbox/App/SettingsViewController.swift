import AppKit
import ServiceManagement

/// Standard Settings window (⌘,). Launch at Login, iCloud Sync and the
/// read-only sync status (PRD §15.2, §15.4).
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let controller = SettingsViewController()
        // The system title sits beside the traffic lights on this OS; the
        // window draws its own, centred in the titlebar zone (same as the
        // Trash surface), with the titlebar kept as chrome.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 252),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Inbox Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 252))
        self.init(window: window)
    }
}

final class SettingsViewController: NSViewController {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let summonCheckbox = NSButton(checkboxWithTitle: "Summon with ⌥ Space", target: nil, action: nil)
    private let syncCheckbox = NSButton(checkboxWithTitle: "iCloud Sync", target: nil, action: nil)
    private let syncNoteLabel = NSTextField(wrappingLabelWithString: "Turning iCloud Sync on or off takes effect the next time Inbox launches.")
    private let syncStatusLabel = NSTextField(wrappingLabelWithString: "")

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 252))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUp()
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshSyncStatus),
            name: .inboxSyncStatusDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func setUp() {
        let generalTitle = makeSectionTitle("General")

        launchAtLoginCheckbox.font = .systemFont(ofSize: 13)
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false

        summonCheckbox.font = .systemFont(ofSize: 13)
        summonCheckbox.target = self
        summonCheckbox.action = #selector(summonToggled)
        summonCheckbox.translatesAutoresizingMaskIntoConstraints = false

        syncCheckbox.font = .systemFont(ofSize: 13)
        syncCheckbox.target = self
        syncCheckbox.action = #selector(syncToggled)
        syncCheckbox.translatesAutoresizingMaskIntoConstraints = false

        syncNoteLabel.font = .systemFont(ofSize: 11)
        syncNoteLabel.textColor = .secondaryLabelColor
        syncNoteLabel.translatesAutoresizingMaskIntoConstraints = false

        syncStatusLabel.font = .systemFont(ofSize: 11)
        syncStatusLabel.textColor = .secondaryLabelColor
        syncStatusLabel.maximumNumberOfLines = 2
        syncStatusLabel.lineBreakMode = .byTruncatingTail
        syncStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [generalTitle, launchAtLoginCheckbox, summonCheckbox, syncCheckbox, syncNoteLabel, syncStatusLabel] {
            view.addSubview(subview)
        }

        let windowTitle = WindowTitleLabel(labelWithString: "Inbox Settings")
        windowTitle.font = Theme.Typography.windowTitle
        windowTitle.textColor = .labelColor
        windowTitle.refusesFirstResponder = true
        windowTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(windowTitle)
        let titleZone = NSLayoutGuide()
        view.addLayoutGuide(titleZone)

        NSLayoutConstraint.activate([
            titleZone.topAnchor.constraint(equalTo: view.topAnchor),
            titleZone.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titleZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            windowTitle.centerXAnchor.constraint(equalTo: titleZone.centerXAnchor),
            windowTitle.centerYAnchor.constraint(equalTo: titleZone.centerYAnchor),

            generalTitle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            generalTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: generalTitle.bottomAnchor, constant: 12),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            summonCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 8),
            summonCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            syncCheckbox.topAnchor.constraint(equalTo: summonCheckbox.bottomAnchor, constant: 8),
            syncCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            syncNoteLabel.topAnchor.constraint(equalTo: syncCheckbox.bottomAnchor, constant: 4),
            syncNoteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            syncNoteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            syncStatusLabel.topAnchor.constraint(equalTo: syncNoteLabel.bottomAnchor, constant: 4),
            syncStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            syncStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            syncStatusLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func refresh() {
        let canLaunch = canManageLaunchAtLogin
        launchAtLoginCheckbox.isEnabled = canLaunch
        if canLaunch {
            launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginCheckbox.state = .off
        }

        summonCheckbox.state = Preferences.isGlobalSummonEnabled ? .on : .off

        syncCheckbox.isEnabled = InboxSyncEngine.hasCloudKitContainerEntitlement()
        syncCheckbox.state = Preferences.isSyncEnabled ? .on : .off
        refreshSyncStatus()
    }

    /// Read-only; no timer — re-rendered on appear and on engine events.
    @objc private func refreshSyncStatus() {
        guard Preferences.isSyncEnabled, InboxSyncEngine.hasCloudKitContainerEntitlement() else {
            syncStatusLabel.stringValue = "Sync is off"
            return
        }
        var lines = ["Last synced: \(Preferences.lastSyncSucceededAt.map(Self.relative) ?? "never")"]
        if let error = Preferences.lastSyncError {
            let when = Preferences.lastSyncErrorAt.map { " (\(Self.relative($0)))" } ?? ""
            lines.append("Last error: \(error)\(when)")
        }
        syncStatusLabel.stringValue = lines.joined(separator: "\n")
    }

    private static func relative(_ date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private var canManageLaunchAtLogin: Bool {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            return false
        }
        return true
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
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
        refresh()
    }

    /// Takes effect immediately: AppDelegate observes the notification and
    /// (un)registers the hot key.
    @objc private func summonToggled(_ sender: NSButton) {
        Preferences.store.set(sender.state == .on, forKey: Preferences.globalSummonKey)
        NotificationCenter.default.post(name: .inboxGlobalSummonDidChange, object: nil)
    }

    @objc private func syncToggled(_ sender: NSButton) {
        Preferences.store.set(sender.state == .on, forKey: Preferences.syncEnabledKey)
        let alert = NSAlert()
        alert.messageText = "iCloud Sync"
        alert.informativeText = "Takes effect the next time Inbox launches."
        alert.runModal()
        refresh()
    }
}
