@testable import MeetingTranscriber
import XCTest

/// The "always record this app" list behind the consent prompt's fourth action,
/// the mirror image of `ConsentDenyListTests`.
final class ConsentAllowListTests: XCTestCase {
    func testEmptyListAllowsNothing() {
        // The control case: an untouched install must keep asking about every
        // browser, or the feature would record without consent.
        let list = ConsentAllowList(allowed: [])
        XCTAssertFalse(list.isAllowed("Aside"))
        XCTAssertFalse(list.isAllowed(""))
    }

    func testAllowingMarksExactlyThatApp() {
        let list = ConsentAllowList(allowed: []).allowing("Google Chrome Beta")
        XCTAssertTrue(list.isAllowed("Google Chrome Beta"))
        XCTAssertFalse(list.isAllowed("Brave Browser"))
    }

    func testAllowingIsIdempotent() {
        let once = ConsentAllowList(allowed: []).allowing("Fjordfox")
        let twice = once.allowing("Fjordfox")
        XCTAssertEqual(twice.allowed, ["Fjordfox"])
        XCTAssertEqual(once, twice)
    }

    func testAllowingIsExactAndCaseSensitive() {
        // A dedicated call browser must not drag its stable sibling along: a
        // prefix or case-insensitive match would record the user's everyday
        // browser without asking.
        let list = ConsentAllowList(allowed: []).allowing("Google Chrome Beta")
        XCTAssertFalse(list.isAllowed("Google Chrome"))
        XCTAssertFalse(list.isAllowed("google chrome beta"))
    }

    func testRevertingRemovesOnlyThatApp() {
        let list = ConsentAllowList(allowed: ["Slack", "Discord", "Aside"])
            .reverting("Discord")
        XCTAssertEqual(list.allowed, ["Slack", "Aside"])
    }

    func testRevertingAnAbsentAppChangesNothing() {
        let list = ConsentAllowList(allowed: ["Slack"])
        XCTAssertEqual(list.reverting("Discord"), list)
        XCTAssertEqual(ConsentAllowList(allowed: []).reverting("Slack").allowed, [])
    }

    func testOrderIsPreservedSoTheSettingsListDoesNotReshuffle() {
        var list = ConsentAllowList(allowed: [])
        for app in ["Slack", "Discord", "Aside"] {
            list = list.allowing(app)
        }
        XCTAssertEqual(list.allowed, ["Slack", "Discord", "Aside"])
    }
}
