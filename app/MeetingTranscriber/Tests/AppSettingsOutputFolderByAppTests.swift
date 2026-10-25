import Foundation
@testable import MeetingTranscriber
import XCTest

/// `AppSettings.outputFolderByApp` and `outputFolderConflict` read through a
/// real defaults suite, the same store `defaults write -dict` writes a plist
/// dictionary into. Its own suite and Keychain account per test, like the
/// other settings tests, so `--parallel` runs never share state.
final class AppSettingsOutputFolderByAppTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var mainDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AppSettingsOutputFolderByAppTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "AppSettingsOutputFolderByAppTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        mainDir = try makeTempDirectory(prefix: "OutputFolderByAppMain")
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount, defaultOutputDir: mainDir)
    }

    override func tearDown() {
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        super.tearDown()
    }

    func testNoKeyIsAnEmptyMapAndNoConflict() {
        XCTAssertTrue(settings.outputFolderByApp.isEmpty)
        XCTAssertNil(settings.outputFolderConflict)
    }

    func testTheStoredDictionaryIsReadBack() {
        defaults.set(
            ["Google Chrome Beta": "/Users/alice/Meetings", "Google Chrome": "/Users/alice/Meetings-personal"],
            forKey: AppOutputFolders.defaultsKey,
        )

        let folders = settings.outputFolderByApp
        XCTAssertEqual(folders.folder(forApp: "Google Chrome Beta")?.path, "/Users/alice/Meetings")
        XCTAssertEqual(folders.folder(forApp: "Google Chrome")?.path, "/Users/alice/Meetings-personal")
        XCTAssertNil(folders.folder(forApp: "Zoom"))
    }

    /// Read on every access, so a `defaults write` made while the app runs
    /// applies to the next recording.
    func testAChangeMadeAfterLaunchIsSeen() {
        XCTAssertTrue(settings.outputFolderByApp.isEmpty)

        defaults.set(["Zoom": "/Users/alice/Zoom"], forKey: AppOutputFolders.defaultsKey)

        XCTAssertEqual(settings.outputFolderByApp.folder(forApp: "Zoom")?.path, "/Users/alice/Zoom")
    }

    /// The conflict is judged against the folder output actually goes to,
    /// here the injected default, which a mapped folder then contains.
    func testAMappedFolderThatIsTheMainFolderIsAConflict() {
        defaults.set(["Zoom": mainDir.path], forKey: AppOutputFolders.defaultsKey)

        XCTAssertEqual(settings.outputFolderConflict?.overlap, .sameFolder)
    }

    func testAnUnrelatedMappedFolderIsNoConflict() throws {
        let other = try makeTempDirectory(prefix: "OutputFolderByAppOther")
        defaults.set(["Zoom": other.path], forKey: AppOutputFolders.defaultsKey)

        XCTAssertNil(settings.outputFolderConflict)
    }
}
