@testable import MeetingTranscriber
import XCTest

/// The persisting adapter for the allow list. Every other test injects the
/// in-memory store, so none of them would notice if this one forgot to write.
@MainActor
final class ConsentAllowListStoreTests: XCTestCase {
    /// A defaults suite of its own per test, torn down at the end, so tests
    /// cannot see each other's writes and none of them touch the real domain.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ConsentAllowListStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create defaults suite")
            return
        }
        defer { DefaultsSuite.remove(suiteName) }
        body(defaults)
    }

    func testFreshInstallAllowsNothing() {
        // The control case for the round-trips below: without it, a store that
        // always reported "allowed" would pass them both.
        withDefaults { defaults in
            let store = ConsentAllowListStore(settings: AppSettings(defaults: defaults))
            XCTAssertEqual(store.allowList.allowed, [])
            XCTAssertFalse(store.isAllowed("Fjordfox"))
        }
    }

    func testAllowSurvivesAFreshReadOfTheSameDefaults() {
        withDefaults { defaults in
            ConsentAllowListStore(settings: AppSettings(defaults: defaults)).allow("Fjordfox")

            // A second settings object over the same defaults stands in for the
            // next launch: the value has to come back off disk, not out of memory.
            let reloaded = ConsentAllowListStore(settings: AppSettings(defaults: defaults))
            XCTAssertTrue(reloaded.isAllowed("Fjordfox"))
        }
    }

    func testRevertSurvivesTooSoASettingsRemoveIsNotUndoneByARelaunch() {
        withDefaults { defaults in
            let store = ConsentAllowListStore(settings: AppSettings(defaults: defaults))
            store.allow("Fjordfox")
            store.allow("Slack")
            store.revert("Fjordfox")

            let reloaded = ConsentAllowListStore(settings: AppSettings(defaults: defaults))
            XCTAssertEqual(reloaded.allowList.allowed, ["Slack"])
        }
    }

    func testAllowListIsKeptApartFromTheDenyList() {
        // Two keys, not one: an Always written through this store must not
        // surface as a Never, or answering Always would silence the app.
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            ConsentAllowListStore(settings: settings).allow("Fjordfox")
            XCTAssertEqual(ConsentDenyListStore(settings: settings).denyList.denied, [])
        }
    }
}
