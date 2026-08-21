import AppKit
import ServiceManagement

/// Standard Settings window (⌘,). Appearance + the two session-level
/// switches that previously lived only in the app / status-item menus.
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let controller = SettingsViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 280))
        self.init(window: window)
    }
}

final class SettingsViewController: NSViewController {
    private let fontSlider = NSSlider()
    private let fontValueLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let syncCheckbox = NSButton(checkboxWithTitle: "iCloud Sync", target: nil, action: nil)
    private let syncNoteLabel = NSTextField(wrappingLabelWithString: "Turning iCloud Sync on or off takes effect the next time Inbox launches.")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
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
        let appearanceTitle = makeSectionTitle("Appearance")
        let fontLabel = NSTextField(labelWithString: "Record text size")
        fontLabel.font = .systemFont(ofSize: 13)
        fontLabel.translatesAutoresizingMaskIntoConstraints = false

        fontSlider.minValue = Double(Preferences.minRecordFontSize)
        fontSlider.maxValue = Double(Preferences.maxRecordFontSize)
        fontSlider.numberOfTickMarks = Int(Preferences.maxRecordFontSize - Preferences.minRecordFontSize) + 1
        fontSlider.allowsTickMarkValuesOnly = true
        fontSlider.tickMarkPosition = .below
        fontSlider.target = self
        fontSlider.action = #selector(fontSliderChanged)
        fontSlider.translatesAutoresizingMaskIntoConstraints = false

        fontValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fontValueLabel.textColor = .secondaryLabelColor
        fontValueLabel.alignment = .right
        fontValueLabel.translatesAutoresizingMaskIntoConstraints = false
        fontValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let smallA = NSTextField(labelWithString: "A")
        smallA.font = .systemFont(ofSize: 11)
        smallA.textColor = .secondaryLabelColor
        smallA.translatesAutoresizingMaskIntoConstraints = false

        let largeA = NSTextField(labelWithString: "A")
        largeA.font = .systemFont(ofSize: 16, weight: .medium)
        largeA.textColor = .secondaryLabelColor
        largeA.translatesAutoresizingMaskIntoConstraints = false

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

        for subview in [
            appearanceTitle, fontLabel, fontValueLabel, smallA, fontSlider, largeA,
            generalTitle, launchAtLoginCheckbox, syncCheckbox, syncNoteLabel
        ] {
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            appearanceTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            appearanceTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            fontLabel.topAnchor.constraint(equalTo: appearanceTitle.bottomAnchor, constant: 12),
            fontLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            fontValueLabel.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontValueLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            smallA.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            smallA.centerYAnchor.constraint(equalTo: fontSlider.centerYAnchor),

            largeA.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            largeA.centerYAnchor.constraint(equalTo: fontSlider.centerYAnchor),

            fontSlider.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 8),
            fontSlider.leadingAnchor.constraint(equalTo: smallA.trailingAnchor, constant: 8),
            fontSlider.trailingAnchor.constraint(equalTo: largeA.leadingAnchor, constant: -8),

            generalTitle.topAnchor.constraint(equalTo: fontSlider.bottomAnchor, constant: 28),
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
        fontSlider.doubleValue = Double(Preferences.recordFontSize)
        fontValueLabel.stringValue = "\(Int(Preferences.recordFontSize.rounded())) pt"

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

    @objc private func fontSliderChanged(_ sender: NSSlider) {
        Preferences.recordFontSize = CGFloat(sender.doubleValue)
        fontValueLabel.stringValue = "\(Int(Preferences.recordFontSize.rounded())) pt"
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
