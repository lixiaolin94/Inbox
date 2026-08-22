import Foundation

/// Startup switches parsed from `CommandLine.arguments`.
///
/// `--db-path` and `--defaults-suite` are the generic overrides.
/// `--ui-smoke` reuses them (filling in a temp database and the smoke suite
/// when they are omitted) so its isolation semantics stay unchanged.
/// `--snapshot-dir` is read only by the smoke: its last step renders the
/// window under every appearance × width × surface to PNGs there.
struct LaunchConfiguration: Equatable {
    static let uiSmokeArgument = "--ui-smoke"
    static let smokeDefaultsSuite = "com.xiaolin.Inbox.smoke"

    enum SyncProbeVerb: String, Equatable {
        case create
        case expect
    }

    var isUISmoke: Bool
    var databasePath: String?
    var defaultsSuiteName: String?
    var syncProbe: SyncProbeVerb?
    var probeContent: String?
    var probeTimeout: TimeInterval
    var snapshotDirectory: String?

    static func parse(
        _ arguments: [String],
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> LaunchConfiguration {
        var isUISmoke = false
        var databasePath: String?
        var defaultsSuiteName: String?
        var syncProbe: SyncProbeVerb?
        var probeContent: String?
        var probeTimeout: TimeInterval = 60
        var snapshotDirectory: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case uiSmokeArgument:
                isUISmoke = true
            case "--db-path":
                index += 1
                if index < arguments.count { databasePath = arguments[index] }
            case "--defaults-suite":
                index += 1
                if index < arguments.count { defaultsSuiteName = arguments[index] }
            case "--sync-probe":
                index += 1
                if index < arguments.count {
                    syncProbe = SyncProbeVerb(rawValue: arguments[index])
                }
            case "--content":
                index += 1
                if index < arguments.count { probeContent = arguments[index] }
            case "--timeout":
                index += 1
                if index < arguments.count, let value = TimeInterval(arguments[index]) {
                    probeTimeout = value
                }
            case "--snapshot-dir":
                index += 1
                if index < arguments.count { snapshotDirectory = arguments[index] }
            default:
                break
            }
            index += 1
        }

        if isUISmoke {
            if databasePath == nil {
                let filename = "inbox-smoke-\(pid).sqlite"
                databasePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
            }
            if defaultsSuiteName == nil {
                defaultsSuiteName = smokeDefaultsSuite
            }
        }

        return LaunchConfiguration(
            isUISmoke: isUISmoke,
            databasePath: databasePath,
            defaultsSuiteName: defaultsSuiteName,
            syncProbe: syncProbe,
            probeContent: probeContent,
            probeTimeout: probeTimeout,
            snapshotDirectory: snapshotDirectory
        )
    }
}
