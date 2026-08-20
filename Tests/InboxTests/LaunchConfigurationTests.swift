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
}
