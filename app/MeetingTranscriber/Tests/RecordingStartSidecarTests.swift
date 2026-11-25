@testable import MeetingTranscriber
import XCTest

/// `RecordingStartSidecar`: the file a recording leaves beside its tracks when
/// it starts, and how crash recovery turns it into a job's app, title and
/// folder.
final class RecordingStartSidecarTests: XCTestCase {
    private static let stem = "20261123_160152"
    private let mapped = URL(fileURLWithPath: "/Users/alice/Meetings", isDirectory: true)

    private func sidecar(app: String = "Google Chrome Beta", stem: String = stem) -> RecordingStartSidecar {
        RecordingStartSidecar(stem: stem, appName: app, title: "All Hands", assignedOutputDir: mapped)
    }

    // MARK: - On disk

    func testWhatIsWrittenReadsBack() throws {
        let dir = try makeTempDirectory(prefix: "startSidecar")
        let written = sidecar()

        written.write(in: dir)

        XCTAssertEqual(RecordingStartSidecar.read(stem: Self.stem, in: dir), written)
        let file = RecordingStartSidecar.url(stem: Self.stem, in: dir)
        XCTAssertEqual(file.lastPathComponent, "\(Self.stem)_start.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "it names the meeting, like the tracks it sits beside")
    }

    func testAMissingOrUnreadableSidecarReadsAsNone() throws {
        let dir = try makeTempDirectory(prefix: "startSidecar")
        XCTAssertNil(RecordingStartSidecar.read(stem: Self.stem, in: dir))

        try Data("not json".utf8).write(to: RecordingStartSidecar.url(stem: Self.stem, in: dir))
        XCTAssertNil(RecordingStartSidecar.read(stem: Self.stem, in: dir))
    }

    func testASidecarNamingAnotherStemIsNotTaken() throws {
        let dir = try makeTempDirectory(prefix: "startSidecar")
        let other = sidecar(stem: "20261123_170000")
        let data = try JSONEncoder().encode(other)
        try data.write(to: RecordingStartSidecar.url(stem: Self.stem, in: dir))

        XCTAssertNil(RecordingStartSidecar.read(stem: Self.stem, in: dir))
    }

    func testItIsRemovedBesideItsMixOnly() throws {
        let dir = try makeTempDirectory(prefix: "startSidecar")
        sidecar().write(in: dir)

        RecordingStartSidecar.remove(besideMix: dir.appendingPathComponent("\(Self.stem)_app.wav"))
        XCTAssertNotNil(RecordingStartSidecar.read(stem: Self.stem, in: dir), "a track that is not the mix removes nothing")

        RecordingStartSidecar.remove(besideMix: dir.appendingPathComponent("\(Self.stem)_mix.wav"))
        XCTAssertNil(RecordingStartSidecar.read(stem: Self.stem, in: dir))
    }

    // MARK: - Recovery

    func testARecoveredRecordingKeepsItsAppTitleAndFolder() {
        let routing = RecordingStartSidecar.recoveredRouting(
            stem: Self.stem, sidecar: sidecar(), folders: AppOutputFolders(folders: ["Google Chrome Beta": mapped]),
        )

        XCTAssertEqual(routing.title, "All Hands")
        XCTAssertEqual(routing.appName, "Google Chrome Beta")
        XCTAssertEqual(routing.assignedOutputDir, mapped)
    }

    func testTheFolderFollowsTheMapAsItIsAtRecovery() {
        let moved = URL(fileURLWithPath: "/Users/alice/Work", isDirectory: true)

        let remapped = RecordingStartSidecar.recoveredRouting(
            stem: Self.stem, sidecar: sidecar(), folders: AppOutputFolders(folders: ["Google Chrome Beta": moved]),
        )
        let unmapped = RecordingStartSidecar.recoveredRouting(stem: Self.stem, sidecar: sidecar(), folders: .empty)

        XCTAssertEqual(remapped.assignedOutputDir, moved)
        XCTAssertNil(unmapped.assignedOutputDir, "an app taken out of the map goes to the main folder")
        XCTAssertEqual(unmapped.appName, "Google Chrome Beta")
    }

    func testAMicrophoneRecordingIsNeverRouted() {
        let folders = AppOutputFolders(folders: [ManualRecordingInfo.microphoneAppName: mapped])

        let routing = RecordingStartSidecar.recoveredRouting(
            stem: Self.stem, sidecar: sidecar(app: ManualRecordingInfo.microphoneAppName), folders: folders,
        )

        XCTAssertNil(routing.assignedOutputDir)
    }

    func testWithoutASidecarARecoveredRecordingIsQueuedAsBefore() {
        let routing = RecordingStartSidecar.recoveredRouting(
            stem: Self.stem, sidecar: nil, folders: AppOutputFolders(folders: ["Unknown": mapped]),
        )

        XCTAssertEqual(routing.title, "Recovered Recording (\(Self.stem))")
        XCTAssertEqual(routing.appName, "Unknown")
        XCTAssertNil(routing.assignedOutputDir)
    }
}
