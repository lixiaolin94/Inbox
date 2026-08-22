import AppKit
import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class LaunchConfigurationTests: XCTestCase {
    func testNormalLaunchLeavesPathsNil() {
        let config = LaunchConfiguration.parse(["Inbox"])
        XCTAssertFalse(config.isUISmoke)
        XCTAssertNil(config.databasePath)
        XCTAssertNil(config.defaultsSuiteName)
    }

    func testUISmokeUsesTempDatabaseAndIsolatedSuite() throws {
        let config = LaunchConfiguration.parse(["Inbox", "--ui-smoke"], pid: 4242)
        XCTAssertTrue(config.isUISmoke)
        XCTAssertEqual(config.defaultsSuiteName, LaunchConfiguration.smokeDefaultsSuite)
        let path = try XCTUnwrap(config.databasePath)
        XCTAssertTrue(path.contains("inbox-smoke-4242.sqlite"))
        XCTAssertTrue(path.contains("inbox-smoke-"))
        XCTAssertNil(config.syncProbe)
        XCTAssertNil(config.snapshotDirectory)
    }

    func testUISmokeParsesSnapshotDirectory() {
        let config = LaunchConfiguration.parse(["Inbox", "--ui-smoke", "--snapshot-dir", "/tmp/inbox-snap"])
        XCTAssertTrue(config.isUISmoke)
        XCTAssertEqual(config.snapshotDirectory, "/tmp/inbox-snap")
    }

    func testGenericPathFlagsOverrideSmokeDefaults() {
        let config = LaunchConfiguration.parse([
            "Inbox", "--ui-smoke", "--db-path", "/tmp/custom.sqlite", "--defaults-suite", "com.example.suite"
        ])
        XCTAssertTrue(config.isUISmoke)
        XCTAssertEqual(config.databasePath, "/tmp/custom.sqlite")
        XCTAssertEqual(config.defaultsSuiteName, "com.example.suite")
    }

    func testSyncProbeCreateParsesContentAndDbPath() {
        let config = LaunchConfiguration.parse([
            "Inbox",
            "--sync-probe", "create",
            "--content", "hello probe",
            "--db-path", "/tmp/inbox-a.sqlite"
        ])
        XCTAssertFalse(config.isUISmoke)
        XCTAssertEqual(config.syncProbe, .create)
        XCTAssertEqual(config.probeContent, "hello probe")
        XCTAssertEqual(config.databasePath, "/tmp/inbox-a.sqlite")
        XCTAssertEqual(config.probeTimeout, 60)
    }

    func testSyncProbeExpectParsesTimeout() {
        let config = LaunchConfiguration.parse([
            "Inbox",
            "--sync-probe", "expect",
            "--content", "hello probe",
            "--timeout", "15",
            "--db-path", "/tmp/inbox-b.sqlite",
            "--defaults-suite", "com.xiaolin.Inbox.probe"
        ])
        XCTAssertEqual(config.syncProbe, .expect)
        XCTAssertEqual(config.probeTimeout, 15)
        XCTAssertEqual(config.defaultsSuiteName, "com.xiaolin.Inbox.probe")
    }
}

final class PreferencesTests: XCTestCase {
    private let suiteName = "com.xiaolin.Inbox.smoke.test"

    override func tearDown() {
        Preferences.configure(suiteName: nil)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSuiteStartsWipedAndIsIsolatedFromStandard() {
        Preferences.configure(suiteName: suiteName)
        XCTAssertNil(Preferences.store.string(forKey: "com.inbox.sortOrder"))
        Preferences.store.set("priority", forKey: "com.inbox.sortOrder")
        XCTAssertEqual(Preferences.store.string(forKey: "com.inbox.sortOrder"), "priority")
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: "com.inbox.sortOrder"), "priority")

        Preferences.configure(suiteName: suiteName)
        XCTAssertNil(Preferences.store.string(forKey: "com.inbox.sortOrder"))
    }

    func testSyncDefaultsToEnabledWhenPreferenceIsMissing() {
        Preferences.configure(suiteName: suiteName)

        XCTAssertNil(Preferences.store.object(forKey: Preferences.syncEnabledKey))
        XCTAssertTrue(Preferences.isSyncEnabled)
    }

    func testSyncCanBeExplicitlyDisabledAndReenabled() {
        Preferences.configure(suiteName: suiteName)

        Preferences.store.set(false, forKey: Preferences.syncEnabledKey)
        XCTAssertFalse(Preferences.isSyncEnabled)

        Preferences.store.set(true, forKey: Preferences.syncEnabledKey)
        XCTAssertTrue(Preferences.isSyncEnabled)
    }

    func testSyncStatusRoundTripsAndClears() {
        Preferences.configure(suiteName: suiteName)
        XCTAssertNil(Preferences.lastSyncSucceededAt)
        XCTAssertNil(Preferences.lastSyncError)
        XCTAssertNil(Preferences.lastSyncErrorAt)

        let succeededAt = Date(timeIntervalSince1970: 1_700_000_000)
        let failedAt = Date(timeIntervalSince1970: 1_700_000_060)
        Preferences.lastSyncSucceededAt = succeededAt
        Preferences.lastSyncError = "save failed 1: boom"
        Preferences.lastSyncErrorAt = failedAt
        XCTAssertEqual(Preferences.lastSyncSucceededAt, succeededAt)
        XCTAssertEqual(Preferences.lastSyncError, "save failed 1: boom")
        XCTAssertEqual(Preferences.lastSyncErrorAt, failedAt)

        Preferences.lastSyncError = nil
        Preferences.lastSyncErrorAt = nil
        XCTAssertNil(Preferences.lastSyncError)
        XCTAssertNil(Preferences.lastSyncErrorAt)
        XCTAssertNil(Preferences.store.object(forKey: "com.inbox.lastSyncError"))
        XCTAssertEqual(Preferences.lastSyncSucceededAt, succeededAt)
    }

    func testRecordFontSizeMatchesSystemBody() {
        Preferences.configure(suiteName: suiteName)
        XCTAssertEqual(Preferences.recordFontSize, NSFont.preferredFont(forTextStyle: .body).pointSize)
    }

    func testRecordRowMinHeightUsesBodyFont() {
        Preferences.configure(suiteName: suiteName)
        let expected = NSFont.preferredFont(forTextStyle: .body).pointSize + 10 * 2
        XCTAssertEqual(Preferences.recordRowMinHeight, expected)
    }
}
