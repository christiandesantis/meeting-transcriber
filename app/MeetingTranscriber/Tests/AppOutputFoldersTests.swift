@testable import MeetingTranscriber
import XCTest

/// `AppOutputFolders`: reading the hidden map, looking an app up in it, and
/// the guard that keeps recording off while the main folder overlaps a mapped
/// one. Pure values, so every case is a plain construction.
final class AppOutputFoldersTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    private let map = AppOutputFolders(folders: [
        "Google Chrome Beta": URL(fileURLWithPath: "/Users/alice/Meetings", isDirectory: true),
        "Google Chrome": URL(fileURLWithPath: "/Users/alice/Meetings-personal", isDirectory: true),
    ])

    // MARK: - Lookup

    func testAMappedAppGetsItsFolder() {
        XCTAssertEqual(map.folder(forApp: "Google Chrome Beta")?.path, "/Users/alice/Meetings")
        XCTAssertEqual(map.folder(forApp: "Google Chrome")?.path, "/Users/alice/Meetings-personal")
    }

    /// Exact names only: a browser fork whose name merely starts with a mapped
    /// one is a different app, and so is a differently cased name.
    func testTheLookupIsExactAndCaseSensitive() {
        XCTAssertNil(map.folder(forApp: "google chrome beta"))
        XCTAssertNil(map.folder(forApp: "Google Chrome Canary"))
        XCTAssertNil(map.folder(forApp: "Google Chrome Beta "))
    }

    func testAnUnmappedAppGetsNoFolder() {
        XCTAssertNil(map.folder(forApp: "Zoom"))
    }

    func testAnEmptyMapRoutesNothingAndRefusesNothing() {
        XCTAssertTrue(AppOutputFolders.empty.isEmpty)
        XCTAssertNil(AppOutputFolders.empty.folder(forApp: "Google Chrome Beta"))
        XCTAssertNil(AppOutputFolders.empty.conflict(withMainFolder: home))
    }

    // MARK: - Reading the default

    /// The shape `defaults write <id> outputFolderByApp -dict "A" "/x" "B" "~/y"`
    /// stores: a dictionary of strings, read back as `[String: Any]`.
    func testReadsWhatDefaultsWriteDictStores() {
        let stored: [String: Any] = [
            "Google Chrome Beta": "/Users/alice/Meetings",
            "Google Chrome": "~/Meetings-personal",
        ]
        let folders = AppOutputFolders(defaultsValue: stored, home: home)

        XCTAssertEqual(folders.folder(forApp: "Google Chrome Beta")?.path, "/Users/alice/Meetings")
        XCTAssertEqual(folders.folder(forApp: "Google Chrome")?.path, "/Users/alice/Meetings-personal")
        XCTAssertEqual(folders.folders.count, 2)
        XCTAssertTrue(folders.unusableApps.isEmpty)
    }

    func testALeadingTildeAloneIsHome() {
        XCTAssertEqual(AppOutputFolders.folder(fromSetting: "~", home: home)?.path, "/Users/alice")
    }

    func testAFolderIsStandardized() {
        XCTAssertEqual(
            AppOutputFolders.folder(fromSetting: "/Users/alice/x/../Meetings/", home: home)?.path,
            "/Users/alice/Meetings",
        )
    }

    func testNoValueIsAnEmptyMap() {
        XCTAssertEqual(AppOutputFolders(defaultsValue: nil, home: home), .empty)
    }

    /// An entry that cannot be used is kept, not dropped: dropping it would
    /// send that app's calls to the main folder, the very thing it was written
    /// to prevent.
    func testUnusableEntriesAreKeptAsUnusable() {
        let stored: [String: Any] = [
            "Zoom": "Meetings", // relative
            "Webex": 42,
            "": "/Users/alice/Meetings",
            "Microsoft Teams": "/Users/alice/Work",
        ]
        let folders = AppOutputFolders(defaultsValue: stored, home: home)

        XCTAssertEqual(folders.unusableApps, ["", "Webex", "Zoom"])
        XCTAssertEqual(folders.folders.keys.sorted(), ["Microsoft Teams"])
        XCTAssertEqual(
            folders.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Elsewhere"))?.overlap,
            .unusableFolder,
        )
    }

    func testAValueThatIsNotADictionaryIsUnusableAsAWhole() {
        let folders = AppOutputFolders(defaultsValue: "/Users/alice/Meetings", home: home)

        XCTAssertFalse(folders.isEmpty)
        XCTAssertEqual(folders.unusableApps, [AppOutputFolders.defaultsKey])
        XCTAssertNotNil(folders.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Elsewhere")))
    }

    // MARK: - The guard

    func testTheMainFolderEqualToAMappedFolderIsRefused() {
        let conflict = map.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Meetings"))

        XCTAssertEqual(conflict?.overlap, .sameFolder)
        XCTAssertEqual(conflict?.appName, "Google Chrome Beta")
    }

    func testTheMainFolderContainingAMappedFolderIsRefused() {
        let conflict = map.conflict(withMainFolder: home)

        XCTAssertEqual(conflict?.overlap, .mainContainsAppFolder)
    }

    func testTheMainFolderInsideAMappedFolderIsRefused() {
        let conflict = map.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Meetings-personal/All"))

        XCTAssertEqual(conflict?.overlap, .mainInsideAppFolder)
        XCTAssertEqual(conflict?.appName, "Google Chrome")
    }

    func testAnUnrelatedMainFolderIsAllowed() {
        XCTAssertNil(map.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Downloads/MeetingTranscriber")))
    }

    /// Compared by path component: `Meetings` is no parent of
    /// `Meetings-personal`, though one string starts with the other.
    func testASiblingSharingANamePrefixIsAllowed() {
        let folders = AppOutputFolders(folders: [
            "Google Chrome": URL(fileURLWithPath: "/Users/alice/Meetings-personal"),
        ])
        XCTAssertNil(folders.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Meetings")))
    }

    func testTheComparisonIgnoresTrailingSlashesDotSegmentsAndCase() {
        XCTAssertEqual(
            map.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/x/../MEETINGS/"))?.overlap,
            .sameFolder,
        )
    }

    /// A main folder reached through a symlink is the folder it points at.
    func testAMainFolderThatIsASymlinkToAMappedFolderIsRefused() throws {
        let root = try makeTempDirectory(prefix: "AppOutputFoldersLink")
        let mapped = root.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: mapped, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Main")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mapped)
        let folders = AppOutputFolders(folders: ["Google Chrome Beta": mapped])

        XCTAssertEqual(folders.conflict(withMainFolder: link)?.overlap, .sameFolder)
    }

    /// Two apps may share one folder: the map says so outright, and it leaks
    /// nothing from one app to another that the user did not ask for.
    func testTwoAppsSharingAFolderIsAllowed() {
        let work = URL(fileURLWithPath: "/Users/alice/Meetings")
        let folders = AppOutputFolders(folders: ["Google Chrome Beta": work, "Microsoft Teams": work])

        XCTAssertNil(folders.conflict(withMainFolder: URL(fileURLWithPath: "/Users/alice/Other")))
    }

    func testTheRefusalNamesTheAppAndTheFolders() throws {
        let conflict = try XCTUnwrap(map.conflict(withMainFolder: home))

        XCTAssertTrue(conflict.message.contains("Google Chrome"), conflict.message)
        XCTAssertTrue(conflict.message.contains("/Users/alice"), conflict.message)
        XCTAssertEqual(conflict.localizedDescription, conflict.message)
    }

    // MARK: - Settings rows

    func testSettingsRowsListEveryEntryInAppNameOrder() {
        let folders = AppOutputFolders(
            folders: [
                "Google Chrome Beta": URL(fileURLWithPath: "/Users/alice/Meetings"),
                "Google Chrome": URL(fileURLWithPath: "/Volumes/Ext/Personal"),
            ],
            unusableApps: ["Zoom"],
        )

        XCTAssertEqual(
            OutputSettingsLogic.appFolderRows(folders, home: home),
            [
                .init(app: "Google Chrome", folder: "/Volumes/Ext/Personal"),
                .init(app: "Google Chrome Beta", folder: "~/Meetings"),
                .init(app: "Zoom", folder: OutputSettingsLogic.unusableFolderNote),
            ],
        )
    }

    func testAnEmptyMapHasNoSettingsRows() {
        XCTAssertTrue(OutputSettingsLogic.appFolderRows(.empty, home: home).isEmpty)
    }
}
