import Foundation

extension Notification.Name {
    static let inboxAppearanceDidChange = Notification.Name("InboxAppearanceDidChange")
}

/// Single UserDefaults access point for persisted UI flags and the small
/// Settings surface (font size, iCloud Sync). Exists so `--ui-smoke` can
/// swap in an isolated suite.
enum Preferences {
    static let syncEnabledKey = "com.inbox.syncEnabled"
    static let recordFontSizeKey = "com.inbox.recordFontSize"

    static let defaultRecordFontSize: CGFloat = 15
    static let minRecordFontSize: CGFloat = 13
    static let maxRecordFontSize: CGFloat = 20
    static let recordVerticalPadding: CGFloat = 10

    private static var defaults: UserDefaults = .standard

    static var store: UserDefaults { defaults }

    /// Missing key means enabled — `bool(forKey:)` would treat that as false.
    static var isSyncEnabled: Bool {
        if store.object(forKey: syncEnabledKey) == nil { return true }
        return store.bool(forKey: syncEnabledKey)
    }

    static var recordFontSize: CGFloat {
        get {
            let stored = store.object(forKey: recordFontSizeKey) as? Double
            let value = stored.map { CGFloat($0) } ?? defaultRecordFontSize
            return min(max(value, minRecordFontSize), maxRecordFontSize)
        }
        set {
            let clamped = min(max(newValue, minRecordFontSize), maxRecordFontSize)
            store.set(Double(clamped), forKey: recordFontSizeKey)
            NotificationCenter.default.post(name: .inboxAppearanceDidChange, object: nil)
        }
    }

    static var recordRowMinHeight: CGFloat {
        recordFontSize + recordVerticalPadding * 2
    }

    /// `suiteName` wipes and uses that suite; `nil` restores `UserDefaults.standard`.
    static func configure(suiteName: String?) {
        if let suiteName {
            let suite = UserDefaults(suiteName: suiteName) ?? .standard
            suite.removePersistentDomain(forName: suiteName)
            defaults = suite
        } else {
            defaults = .standard
        }
    }
}
