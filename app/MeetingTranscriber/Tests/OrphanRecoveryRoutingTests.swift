@testable import MeetingTranscriber
import XCTest

/// A recording whose process died mid-meeting is queued again by the orphan
/// scan under the app and title it was started with, in the folder the
/// per-app map gives that app, read from the start sidecar beside its tracks.
/// Without the sidecar it is queued as it always was.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class OrphanRecoveryRoutingTests: XCTestCase {
    private static let stem = "20260311_100000"
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var recDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional
    private let mapped = URL(fileURLWithPath: "/tmp/work-meetings", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "OrphanRecoveryRoutingTests")
        recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(Self.stem)_mix.wav"))
    }

    private func recover(folders: AppOutputFolders) async throws -> PipelineJob {
        let queue = PipelineQueue(logDir: tmpDir)
        queue.outputFolders = { folders }
        await queue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertEqual(queue.jobs.count, 1)
        return try XCTUnwrap(queue.jobs.first)
    }

    func testARecoveredRecordingIsRoutedByItsStartSidecar() async throws {
        RecordingStartSidecar(
            stem: Self.stem, appName: "Google Chrome Beta", title: "All Hands", assignedOutputDir: mapped,
        ).write(in: recDir)

        let job = try await recover(folders: AppOutputFolders(folders: ["Google Chrome Beta": mapped]))

        XCTAssertEqual(job.appName, "Google Chrome Beta")
        XCTAssertEqual(job.meetingTitle, "All Hands")
        XCTAssertEqual(job.assignedOutputDir, mapped)
        XCTAssertNotNil(
            RecordingStartSidecar.read(stem: Self.stem, in: recDir),
            "kept until the audio leaves staging, for a process that dies before the job is saved",
        )
    }

    func testAnAppNoLongerMappedIsRecoveredIntoTheMainFolder() async throws {
        RecordingStartSidecar(
            stem: Self.stem, appName: "Google Chrome Beta", title: "All Hands", assignedOutputDir: mapped,
        ).write(in: recDir)

        let job = try await recover(folders: .empty)

        XCTAssertEqual(job.appName, "Google Chrome Beta")
        XCTAssertNil(job.assignedOutputDir)
    }

    func testWithoutAStartSidecarARecoveredRecordingIsQueuedAsBefore() async throws {
        let job = try await recover(folders: AppOutputFolders(folders: ["Google Chrome Beta": mapped]))

        XCTAssertEqual(job.appName, "Unknown")
        XCTAssertEqual(job.meetingTitle, "Recovered Recording (\(Self.stem))")
        XCTAssertNil(job.assignedOutputDir)
    }
}
