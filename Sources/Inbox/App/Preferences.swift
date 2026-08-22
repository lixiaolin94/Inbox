import AppKit

extension Notification.Name {
    static let inboxAppearanceDidChange = Notification.Name("InboxAppearanceDidChange")
}

/// Single UserDefaults access point for persisted UI state (last Scope,
/// collapsed groups, sort, Show Resolved) and the small Settings surface
/// (Launch at Login / iCloud Sync). Exists so `--ui-smoke` can swap in an
/// isolated suite, and so no view controller owns a defaults key.
enum Preferences {
    static let syncEnabledKey = "com.inbox.syncEnabled"
    private static let lastScopeProjectIDKey = "com.inbox.lastScopeProjectID"
    private static let collapsedGroupsKey = "com.inbox.collapsedGroups"
    private static let sortOrderKey = "com.inbox.sortOrder"
    private static let showResolvedKey = "com.inbox.showResolved"

    static let recordVerticalPadding: CGFloat = 10

    private static var defaults: UserDefaults = .standard

    static var store: UserDefaults { defaults }

    /// Missing key means enabled — `bool(forKey:)` would treat that as false.
    static var isSyncEnabled: Bool {
        if store.object(forKey: syncEnabledKey) == nil { return true }
        return store.bool(forKey: syncEnabledKey)
    }

    /// macOS body text style (HIG). Not user-adjustable.
    static var recordFontSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    static var recordRowMinHeight: CGFloat {
        recordFontSize + recordVerticalPadding * 2
    }

    // MARK: - Main surface list state

    /// Last selected Project Scope; nil means All (PRD §7.1). Callers must
    /// check the id against the live Project list before using it.
    static var lastScopeProjectID: String? {
        get { store.string(forKey: lastScopeProjectIDKey) }
        set {
            if let newValue {
                store.set(newValue, forKey: lastScopeProjectIDKey)
            } else {
                store.removeObject(forKey: lastScopeProjectIDKey)
            }
        }
    }

    /// Global list sort (PRD §10).
    static var sortOrder: RecordSort {
        get { RecordSort(rawValue: store.string(forKey: sortOrderKey) ?? "") ?? .newestFirst }
        set { store.set(newValue.rawValue, forKey: sortOrderKey) }
    }

    /// Show Resolved visibility (PRD §11). Default Off.
    static var showResolved: Bool {
        get { store.bool(forKey: showResolvedKey) }
        set { store.set(newValue, forKey: showResolvedKey) }
    }

    /// All View fold state per Project group (PRD §7.2).
    static func isGroupCollapsed(_ id: GroupID) -> Bool {
        collapsedGroupKeys.contains(collapseKey(id))
    }

    static func setGroupCollapsed(_ id: GroupID, _ collapsed: Bool) {
        var keys = collapsedGroupKeys
        if collapsed {
            keys.insert(collapseKey(id))
        } else {
            keys.remove(collapseKey(id))
        }
        store.set(Array(keys), forKey: collapsedGroupsKey)
    }

    /// Reads and parses the defaults array each time; callers that test many
    /// groups in one pass should snapshot this once and use `collapseKey`.
    static var collapsedGroupKeys: Set<String> {
        Set(store.stringArray(forKey: collapsedGroupsKey) ?? [])
    }

    static func collapseKey(_ id: GroupID) -> String {
        switch id {
        case .inbox: return "inbox"
        case .project(let projectID): return projectID
        }
    }

    // MARK: - Suite

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
