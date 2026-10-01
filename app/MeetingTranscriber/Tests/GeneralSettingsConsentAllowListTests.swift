@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring test for the always-record list in the General tab, the mirror of
/// `GeneralSettingsConsentDenyListTests`. `ConsentAllowListTests` owns the list
/// logic; this only proves the tab renders the rows and that Remove writes back,
/// which is the user's only way to undo an "Always for this app".
@MainActor
final class GeneralSettingsConsentAllowListTests: XCTestCase {
    private func makeSettings(allowed: [String]) throws -> AppSettings {
        let suiteName = "GeneralSettingsConsentAllowListTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchBrowserMeetings = true
        settings.consentAllowedApps = allowed
        return settings
    }

    private func view(allowed: [String]) throws -> GeneralSettingsView {
        try GeneralSettingsView(settings: makeSettings(allowed: allowed), notificationVisibility: nil)
    }

    func testSectionIsHiddenWhenNothingIsAllowed() throws {
        let view = try view(allowed: [])
        XCTAssertNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentAllowListSection),
        )
    }

    func testAllowedAppsAreListed() throws {
        let view = try view(allowed: ["Fjordfox", "Slack"])
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentAllowListSection),
        )
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentAllowedAppRemove(0)),
        )
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentAllowedAppRemove(1)),
        )
    }

    func testRemoveIdentifiersCarryNoAppNames() throws {
        // Same rule as the deny list: `GET /ui/tree` publishes identifiers
        // unredacted, so an app name here would leak which apps are recorded.
        let view = try view(allowed: ["Fjordfox", "Slack"])
        for app in ["Fjordfox", "Slack"] {
            XCTAssertNil(
                try? view.inspect().find(viewWithAccessibilityIdentifier: "consentAllowedAppRemove.\(app)"),
                "\(app): the row identifier must not carry the app name",
            )
        }
    }

    func testRemoveWritesBackAndLeavesTheOtherEntries() throws {
        let settings = try makeSettings(allowed: ["Fjordfox", "Slack"])
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.consentAllowedAppRemove(0))
            .button()
            .tap()
        XCTAssertEqual(settings.consentAllowedApps, ["Slack"])
    }
}
