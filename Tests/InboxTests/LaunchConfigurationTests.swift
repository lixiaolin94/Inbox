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

    func testRecordFontSizeDefaultsToFifteen() {
        Preferences.configure(suiteName: suiteName)
        XCTAssertEqual(Preferences.recordFontSize, Preferences.defaultRecordFontSize)
    }

    func testRecordFontSizeClampsToSupportedRange() {
        Preferences.configure(suiteName: suiteName)
        Preferences.recordFontSize = 99
        XCTAssertEqual(Preferences.recordFontSize, Preferences.maxRecordFontSize)
        Preferences.recordFontSize = 8
        XCTAssertEqual(Preferences.recordFontSize, Preferences.minRecordFontSize)
        Preferences.recordFontSize = 17
        XCTAssertEqual(Preferences.recordFontSize, 17)
    }

    func testRecordRowMinHeightTracksFontSize() {
        Preferences.configure(suiteName: suiteName)
        Preferences.recordFontSize = 15
        XCTAssertEqual(Preferences.recordRowMinHeight, 35)
        Preferences.recordFontSize = 18
        XCTAssertEqual(Preferences.recordRowMinHeight, 38)
    }
}
