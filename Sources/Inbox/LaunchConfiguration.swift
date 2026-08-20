import Foundation

/// Startup switches parsed from `CommandLine.arguments`.
///
/// `--ui-smoke` redirects the database and preferences to throwaway
/// locations so the in-process UI smoke run never touches the user's
/// real Inbox files. Normal launches leave both fields nil.
struct LaunchConfiguration: Equatable {
    static let uiSmokeArgument = "--ui-smoke"
    static let smokeDefaultsSuite = "com.xiaolin.Inbox.smoke"

    var isUISmoke: Bool
    var databasePath: String?
    var defaultsSuiteName: String?

    static func parse(
        _ arguments: [String],
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> LaunchConfiguration {
        guard arguments.contains(uiSmokeArgument) else {
            return LaunchConfiguration(isUISmoke: false, databasePath: nil, defaultsSuiteName: nil)
        }
        let filename = "inbox-smoke-\(pid).sqlite"
        let databasePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
        return LaunchConfiguration(
            isUISmoke: true,
            databasePath: databasePath,
            defaultsSuiteName: smokeDefaultsSuite
        )
    }
}
