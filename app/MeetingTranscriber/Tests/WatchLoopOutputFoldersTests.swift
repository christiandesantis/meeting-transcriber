@testable import MeetingTranscriber
import XCTest

/// How `WatchLoop` uses the per-app output folders: the folder a recording is
/// assigned when it is handed on, record-only landing in it, and the refusal
/// to record while the main output folder overlaps one of them.
@MainActor
final class WatchLoopOutputFoldersTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    private static let browser = "Microsoft Teams" // the app name a detected Teams call is carried under

    private func makeLoop(
        queue: PipelineQueue? = nil,
        recorder: MockRecorder = MockRecorder(),
        folders: AppOutputFolders = .empty,
        conflict: AppOutputFolders.Conflict? = nil,
        conflictProvider: (() -> AppOutputFolders.Conflict?)? = nil,
        recordOnly: Bool = false,
        recordOnlyDir: URL? = nil,
        notifier: any AppNotifying = SilentNotifier(),
    ) -> WatchLoop {
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            noMic: true,
            recordOnly: { recordOnly },
            recordOnlyDestination: { .unscoped(recordOnlyDir ?? AppPaths.recordingsDir) },
            outputFolders: { folders },
            outputFolderConflict: conflictProvider ?? { conflict },
            notifier: notifier,
        )
        loop.permissionChecker = { .allHealthy }
        return loop
    }

    private func meeting(pattern: AppMeetingPattern = .teams) -> DetectedMeeting {
        DetectedMeeting(
            pattern: pattern,
            windowTitle: "Standup",
            ownerName: pattern.appName,
            windowPID: 9999,
        )
    }

    private func conflict(main: URL, mapped: URL) throws -> AppOutputFolders.Conflict {
        try XCTUnwrap(AppOutputFolders(folders: [Self.browser: mapped]).conflict(withMainFolder: main))
    }

    // MARK: - Routing

    func testAMappedAppsJobIsAssignedItsFolder() throws {
        let mapped = URL(fileURLWithPath: "/tmp/work-meetings", isDirectory: true)
        let loop = makeLoop(folders: AppOutputFolders(folders: [Self.browser: mapped]))

        XCTAssertEqual(loop.assignedOutputFolder(forApp: Self.browser), mapped)
        XCTAssertNil(loop.assignedOutputFolder(forApp: "Zoom"), "an unmapped app uses the main folder")
        XCTAssertNil(loop.assignedOutputFolder(forApp: "microsoft teams"), "the lookup is case sensitive")
    }

    func testMicrophoneOnlyRecordingsAreNeverRouted() {
        let mapped = URL(fileURLWithPath: "/tmp/mic-folder", isDirectory: true)
        let loop = makeLoop(folders: AppOutputFolders(folders: [ManualRecordingInfo.microphoneAppName: mapped]))

        XCTAssertNil(loop.assignedOutputFolder(forApp: ManualRecordingInfo.microphoneAppName))
    }

    func testTheEnqueuedJobCarriesTheAssignedFolder() async throws {
        let mapped = URL(fileURLWithPath: "/tmp/work-meetings", isDirectory: true)
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_per_app_routing.wav")
        let queue = PipelineQueue()
        let loop = makeLoop(queue: queue, recorder: recorder, folders: AppOutputFolders(folders: [Self.browser: mapped]))

        try await loop.handleMeeting(meeting())

        XCTAssertEqual(queue.jobs.first?.assignedOutputDir, mapped)
    }

    func testAnUnmappedAppsJobCarriesNoFolder() async throws {
        let mapped = URL(fileURLWithPath: "/tmp/work-meetings", isDirectory: true)
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_per_app_unmapped.wav")
        let queue = PipelineQueue()
        let loop = makeLoop(queue: queue, recorder: recorder, folders: AppOutputFolders(folders: [Self.browser: mapped]))

        try await loop.handleMeeting(meeting(pattern: .zoom))

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertNil(queue.jobs.first?.assignedOutputDir)
    }

    func testRecordOnlyWritesIntoTheMappedAppsFolder() async throws {
        let tmp = try makeTempDirectory(prefix: "perAppRecordOnly")
        let mapped = tmp.appendingPathComponent("mapped", isDirectory: true)
        let fallback = tmp.appendingPathComponent("fallback", isDirectory: true)
        let mix = tmp.appendingPathComponent("20260503_120000_mix.wav")
        try Data().write(to: mix)
        let recorder = MockRecorder()
        recorder.mixPath = mix
        let loop = makeLoop(
            recorder: recorder, folders: AppOutputFolders(folders: [Self.browser: mapped]),
            recordOnly: true, recordOnlyDir: fallback,
        )

        try await loop.handleMeeting(meeting())

        let moved = mapped.appendingPathComponent("recordings/20260503_120000_mix.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path), "the main destination is not touched")
    }

    // MARK: - The guard

    func testManualRecordingIsRefusedWhileTheFoldersOverlap() async throws {
        let folder = URL(fileURLWithPath: "/tmp/overlap", isDirectory: true)
        let overlap = try conflict(main: folder, mapped: folder)
        let recorder = MockRecorder()
        let loop = makeLoop(recorder: recorder, conflict: overlap)

        do {
            try await loop.startManualRecording(pid: 42, appName: Self.browser, title: "Standup")
            XCTFail("recording must be refused")
        } catch let error as AppOutputFolders.Conflict {
            XCTAssertEqual(error, overlap)
        }

        XCTAssertNotEqual(loop.state, .recording)
    }

    func testManualRecordingStartsWithoutAConflict() async throws {
        let loop = makeLoop()

        try await loop.startManualRecording(pid: 42, appName: Self.browser, title: "Standup")

        XCTAssertEqual(loop.state, .recording)
        loop.stopManualRecording()
    }

    func testARefusalIsNotifiedOnceUntilItClears() throws {
        let folder = URL(fileURLWithPath: "/tmp/overlap", isDirectory: true)
        let overlap = try conflict(main: folder, mapped: folder)
        let notifier = RecordingNotifier()
        var current: AppOutputFolders.Conflict? = overlap
        let loop = makeLoop(conflictProvider: { current }, notifier: notifier)

        XCTAssertTrue(loop.refusesRecordingForOutputFolders())
        XCTAssertTrue(loop.refusesRecordingForOutputFolders())
        XCTAssertEqual(notifier.calls.count, 1, "a refusal that stays is told once")
        XCTAssertEqual(notifier.calls.first?.title, WatchLoop.outputConflictTitle)
        XCTAssertEqual(notifier.calls.first?.body, overlap.message)

        current = nil
        XCTAssertFalse(loop.refusesRecordingForOutputFolders())

        current = overlap
        XCTAssertTrue(loop.refusesRecordingForOutputFolders())
        XCTAssertEqual(notifier.calls.count, 2, "the same refusal after it cleared is told again")
    }
}
