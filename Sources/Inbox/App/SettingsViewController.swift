import AppKit
import ServiceManagement

/// Standard Settings window (⌘,). Launch at Login and iCloud Sync.
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let controller = SettingsViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 180))
        self.init(window: window)
    }
}

final class SettingsViewController: NSViewController {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let syncCheckbox = NSButton(checkboxWithTitle: "iCloud Sync", target: nil, action: nil)
    private let syncNoteLabel = NSTextField(wrappingLabelWithString: "Turning iCloud Sync on or off takes effect the next time Inbox launches.")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUp()
        refresh()
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

        syncCheckbox.font = .systemFont(ofSize: 13)
        syncCheckbox.target = self
        syncCheckbox.action = #selector(syncToggled)
        syncCheckbox.translatesAutoresizingMaskIntoConstraints = false

        syncNoteLabel.font = .systemFont(ofSize: 11)
        syncNoteLabel.textColor = .secondaryLabelColor
        syncNoteLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [generalTitle, launchAtLoginCheckbox, syncCheckbox, syncNoteLabel] {
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            generalTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            generalTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: generalTitle.bottomAnchor, constant: 12),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            syncCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 8),
            syncCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            syncNoteLabel.topAnchor.constraint(equalTo: syncCheckbox.bottomAnchor, constant: 4),
            syncNoteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            syncNoteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            syncNoteLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
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

        syncCheckbox.isEnabled = InboxSyncEngine.hasCloudKitContainerEntitlement()
        syncCheckbox.state = Preferences.isSyncEnabled ? .on : .off
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

    @objc private func syncToggled(_ sender: NSButton) {
        Preferences.store.set(sender.state == .on, forKey: Preferences.syncEnabledKey)
        let alert = NSAlert()
        alert.messageText = "iCloud Sync"
        alert.informativeText = "Takes effect the next time Inbox launches."
        alert.runModal()
        refresh()
    }
}
