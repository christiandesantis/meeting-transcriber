@testable import MeetingTranscriber
import XCTest

/// A job assigned its own output folder writes everything under that folder
/// and nothing under the queue's: the draft and final transcript, the
/// protocol, the relocated audio, the naming sidecars, and what a late
/// re-diarization reads and rewrites. A job without one, and every job from a
/// snapshot written before the field existed, keeps the queue's folder.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PerAppOutputFolderPipelineTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var main: URL!
    private var mapped: URL!
    private var staging: URL!
    private var logDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        main = try makeTempDirectory(prefix: "PerAppMain")
        mapped = try makeTempDirectory(prefix: "PerAppMapped")
        staging = try makeTempDirectory(prefix: "PerAppStaging")
        logDir = try makeTempDirectory(prefix: "PerAppLog")
    }

    // MARK: - A mapped job

    /// The whole life of a mapped dual-source job, through a late re-run, with
    /// the queue's own folder checked empty at both ends. The re-run can only
    /// reach `.done` by reading the audio sidecars back, so it also proves the
    /// reads follow the job's folder.
    func testEveryWriteOfAMappedJobLandsInItsFolder() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "First"),
            TimestampedSegment(start: 5, end: 10, text: "Second"),
        ]
        let diarization = MockDiarization()
        diarization.resultToReturn = Self.diarization(speakers: 1)
        let queue = makeQueue(engine: engine, diarization: diarization)
        let job = try makeStagedDualSourceJob(assignedOutputDir: mapped)
        let mappedRecordings = mapped.appendingPathComponent("recordings")
        let mappedProtocols = mapped.appendingPathComponent("protocols")

        await waitForState(queue, jobID: job.id, .speakerNamingPending) {
            queue.enqueue(job)
        }

        let parked = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        let slug = try XCTUnwrap(parked.namingSlug)
        XCTAssertEqual(parked.transcriptPath?.deletingLastPathComponent().path, mappedProtocols.path)
        for path in [parked.mixPath, parked.appPath, parked.micPath] {
            XCTAssertEqual(path?.deletingLastPathComponent().path, mappedRecordings.path, "audio is moved into the job's folder")
        }
        for suffix in SidecarFixture.suffixes {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: mappedRecordings.appendingPathComponent("\(slug)\(suffix)").path),
                "\(suffix) belongs under the job's folder",
            )
        }
        XCTAssertEqual(parked.sidecarOutputDirs.map(\.path), [mapped.path])
        try assertEmpty(main, "nothing of a mapped job goes to the main folder")

        let runsBefore = diarization.runCount
        diarization.resultToReturn = Self.diarization(speakers: 2)
        queue.speakerNamingHandler = { _ in .confirmed(["R_SPEAKER_0": "Alice", "R_SPEAKER_1": "Bob"]) }
        await waitForState(queue, jobID: job.id, .done) {
            queue.completeSpeakerNaming(jobID: job.id, result: .rerun(2))
        }

        XCTAssertGreaterThan(diarization.runCount, runsBefore, "the re-run diarized the job's own sidecars")
        let done = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        let protocolPath = try XCTUnwrap(done.protocolPath)
        XCTAssertEqual(protocolPath.deletingLastPathComponent().path, mappedProtocols.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protocolPath.path))
        let transcript = try String(contentsOf: XCTUnwrap(done.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("] Bob: Second"), "the re-run's speakers were written to the job's transcript")
        try assertEmpty(main, "nothing of a mapped job goes to the main folder, the late re-run included")
    }

    func testAnUnmappedJobStillWritesToTheMainFolder() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarization: nil)
        let job = try PipelineJob(
            meetingTitle: "Unmapped", appName: "Zoom",
            mixPath: createTestAudioFile(in: staging), appPath: nil, micPath: nil, micDelay: 0,
        )

        await waitForState(queue, jobID: job.id, .done) {
            queue.enqueue(job)
        }

        let done = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        let protocols = main.appendingPathComponent("protocols").path
        XCTAssertEqual(done.transcriptPath?.deletingLastPathComponent().path, protocols)
        XCTAssertEqual(done.protocolPath?.deletingLastPathComponent().path, protocols)
        XCTAssertEqual(done.mixPath?.deletingLastPathComponent().path, main.appendingPathComponent("recordings").path)
        try assertEmpty(mapped, "an unmapped job never reaches another app's folder")
    }

    // MARK: - Restoring

    /// A snapshot the previous build wrote has no such key. Its jobs must
    /// restore and run against the queue's folder, as they always did.
    func testASnapshotFromBeforeTheFieldRestoresWithTheQueueFolder() async throws {
        let job = try PipelineJob(
            meetingTitle: "Legacy", appName: "Google Chrome Beta",
            mixPath: createTestAudioFile(in: staging), appPath: nil, micPath: nil, micDelay: 0,
        )
        let encoded = try JSONEncoder().encode(job)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "assignedOutputDir")
        XCTAssertNil(fields["assignedOutputDir"], "test premise: the old build wrote no such key")
        try JSONSerialization.data(withJSONObject: [fields])
            .write(to: logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarization: nil)
        await waitForState(queue, jobID: job.id, .done) {
            queue.loadSnapshot()
        }

        let restored = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertNil(restored.assignedOutputDir)
        XCTAssertEqual(queue.outputRoot(of: restored)?.path, main.path)
        XCTAssertEqual(restored.transcriptPath?.deletingLastPathComponent().path, main.appendingPathComponent("protocols").path)
        try assertEmpty(mapped, "a legacy job is not moved into a per-app folder")
    }

    /// A job interrupted mid-run comes back with the folder it was assigned,
    /// whatever folder the restoring queue writes to.
    func testARestoredJobKeepsItsAssignedFolder() async throws {
        var job = try PipelineJob(
            meetingTitle: "Interrupted", appName: "Google Chrome Beta",
            mixPath: createTestAudioFile(in: staging), appPath: nil, micPath: nil, micDelay: 0,
            assignedOutputDir: mapped,
        )
        job.state = .transcribing
        try PipelineSnapshot.save([job], to: logDir)

        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarization: nil)
        await waitForState(queue, jobID: job.id, .done) {
            queue.loadSnapshot()
        }

        let restored = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(restored.assignedOutputDir?.path, mapped.path)
        XCTAssertEqual(
            restored.protocolPath?.deletingLastPathComponent().path,
            mapped.appendingPathComponent("protocols").path,
        )
        try assertEmpty(main, "a restored mapped job does not fall back to the queue's folder")
    }

    // MARK: - Removing

    /// With raw transcripts switched off, the segments a finished job leaves
    /// are deleted from its own folder, and a file of the same name under the
    /// queue's folder is not the job's to touch.
    func testTheSegmentsSidecarIsRemovedFromTheJobsFolder() throws {
        let queue = makeQueue(engine: MockEngine(), diarization: nil)
        let slug = "meeting"
        let ownSegments = try makeRecordingsDir(in: mapped).appendingPathComponent("\(slug)_segments.json")
        let otherSegments = try makeRecordingsDir(in: main).appendingPathComponent("\(slug)_segments.json")
        try Data("[]".utf8).write(to: ownSegments)
        try Data("[]".utf8).write(to: otherSegments)
        let transcript = mapped.appendingPathComponent("meeting.txt")
        let protocolFile = mapped.appendingPathComponent("meeting.md")
        try Data("words".utf8).write(to: transcript)
        try Data("# Minutes".utf8).write(to: protocolFile)
        var job = PipelineJob(
            meetingTitle: "Meeting", appName: "Google Chrome Beta",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            saveRawTranscriptSeparately: false, assignedOutputDir: mapped,
        )
        job.state = .generatingProtocol
        job.namingSlug = slug
        job.transcriptPath = transcript
        job.protocolPath = protocolFile
        queue.insertJobForTesting(job)

        queue.updateJobState(id: job.id, to: .done)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownSegments.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherSegments.path))
    }

    // MARK: - Arrangement

    private func makeQueue(engine: MockEngine, diarization: MockDiarization?) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization ?? MockDiarization() },
            diarizationFactoryWithMode: { _ in diarization ?? MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: main,
            logDir: logDir,
            stagingDir: staging,
            diarizeEnabled: diarization != nil,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    /// A dual-source job whose three tracks sit in the staging folder, so
    /// stage 3 moves all of them.
    private func makeStagedDualSourceJob(assignedOutputDir: URL) throws -> PipelineJob {
        let mix = try createTestAudioFile(in: staging)
        let app = staging.appendingPathComponent("\(UUID().uuidString)_app.wav")
        let mic = staging.appendingPathComponent("\(UUID().uuidString)_mic.wav")
        try FileManager.default.copyItem(at: mix, to: app)
        try FileManager.default.copyItem(at: mix, to: mic)
        return PipelineJob(
            meetingTitle: "Work Call", appName: "Google Chrome Beta",
            mixPath: mix, appPath: app, micPath: mic, micDelay: 0,
            assignedOutputDir: assignedOutputDir,
        )
    }

    /// One speaker over the whole recording, or two splitting it, with
    /// embeddings so the job parks for naming.
    private static func diarization(speakers: Int) -> DiarizationResult {
        if speakers == 1 {
            return DiarizationResult(
                segments: [.init(start: 0, end: 10, speaker: "SPEAKER_0")],
                speakingTimes: ["SPEAKER_0": 10],
                autoNames: [:],
                embeddings: ["SPEAKER_0": [1, 0, 0]],
            )
        }
        return DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
    }

    private func waitForState(
        _ queue: PipelineQueue, jobID: UUID, _ state: JobState, _ run: () -> Void,
    ) async {
        let reached = expectation(description: "job reached \(state)")
        reached.assertForOverFulfill = false
        queue.onJobStateChange = { job, _, new in
            if job.id == jobID, new == state { reached.fulfill() }
        }
        run()
        await fulfillment(of: [reached], timeout: 30)
        queue.onJobStateChange = nil
    }

    private func assertEmpty(_ folder: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(contents, [], message, file: file, line: line)
    }
}
