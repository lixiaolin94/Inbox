import Foundation

/// Single UserDefaults access point for the handful of persisted UI flags
/// (last Scope, collapsed groups, sort, Show Resolved). Exists so `--ui-smoke`
/// can swap in an isolated suite; not a general settings system.
enum Preferences {
    private static var defaults: UserDefaults = .standard

    static var store: UserDefaults { defaults }

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
