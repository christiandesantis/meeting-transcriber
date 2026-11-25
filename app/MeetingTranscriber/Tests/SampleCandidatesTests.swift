@testable import MeetingTranscriber
import XCTest

/// The pure helpers behind the naming dialog's Play and "next sample"
/// buttons: joining a speaker's segments into turns, ranking the turns, and
/// what the row says about the one being played.
@MainActor
final class SampleCandidatesTests: XCTestCase {
    private typealias Seg = PipelineQueue.SpeakerNamingData.Segment

    private func spans(_ segments: [Seg]) -> [[Double]] {
        segments.map { [$0.start, $0.end] }
    }

    // MARK: - Turns

    func testSegmentsSeparatedByAShortPauseJoinIntoOneTurn() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 1.5, speaker: "SPEAKER_0"),
            Seg(start: 2.0, end: 3.5, speaker: "SPEAKER_0"), // 0.5 s pause
            Seg(start: 4.0, end: 6.0, speaker: "SPEAKER_0"), // 0.5 s pause
        ]

        XCTAssertEqual(spans(SpeakerNamingView.speakerTurns(for: "SPEAKER_0", in: segments)), [[0.0, 6.0]])
    }

    func testAPauseOfAtLeastMaxGapStartsANewTurn() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 2.0, speaker: "SPEAKER_0"),
            Seg(start: 3.0, end: 5.0, speaker: "SPEAKER_0"), // exactly 1 s
        ]

        XCTAssertEqual(
            spans(SpeakerNamingView.speakerTurns(for: "SPEAKER_0", in: segments)), [[0.0, 2.0], [3.0, 5.0]],
        )
    }

    func testAnotherSpeakerInThePauseKeepsTheTurnsApart() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 2.0, speaker: "SPEAKER_0"),
            Seg(start: 2.1, end: 2.4, speaker: "SPEAKER_1"), // a short "yes" in the pause
            Seg(start: 2.5, end: 5.0, speaker: "SPEAKER_0"),
        ]

        XCTAssertEqual(
            spans(SpeakerNamingView.speakerTurns(for: "SPEAKER_0", in: segments)), [[0.0, 2.0], [2.5, 5.0]],
        )
    }

    func testOverlappingAndUnsortedSegmentsOfOneSpeakerJoin() {
        let segments: [Seg] = [
            Seg(start: 3.0, end: 6.0, speaker: "SPEAKER_0"),
            Seg(start: 0.0, end: 4.0, speaker: "SPEAKER_0"),
        ]

        XCTAssertEqual(spans(SpeakerNamingView.speakerTurns(for: "SPEAKER_0", in: segments)), [[0.0, 6.0]])
    }

    // MARK: - Candidates

    func testPureTurnsComeFirstByLengthThenTheRestByLength() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 2.0, speaker: "SPEAKER_0"), // pure, 2 s
            Seg(start: 10.0, end: 20.0, speaker: "SPEAKER_0"), // contaminated, 10 s
            Seg(start: 19.8, end: 22.0, speaker: "SPEAKER_1"),
            Seg(start: 30.0, end: 34.0, speaker: "SPEAKER_0"), // pure, 4 s
            Seg(start: 40.0, end: 41.0, speaker: "SPEAKER_0"), // pure but under 1.5 s
        ]

        XCTAssertEqual(
            spans(SpeakerNamingView.sampleCandidates(for: "SPEAKER_0", in: segments)),
            [[30.0, 34.0], [0.0, 2.0], [10.0, 20.0], [40.0, 41.0]],
        )
    }

    /// The case the turns exist for: no single segment reaches the purity
    /// minimum, but the sentence they make up does, and is played whole.
    func testShortSegmentsOfOneSentenceMakeOnePureCandidate() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 1.2, speaker: "SPEAKER_0"),
            Seg(start: 1.6, end: 2.8, speaker: "SPEAKER_0"),
            Seg(start: 3.2, end: 4.4, speaker: "SPEAKER_0"),
            Seg(start: 20.0, end: 25.0, speaker: "SPEAKER_1"),
        ]

        let first = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)

        XCTAssertEqual(first?.start, 0.0)
        XCTAssertEqual(first?.end, 4.4)
    }

    func testASpeakerWithoutSegmentsHasNoCandidates() {
        let segments: [Seg] = [Seg(start: 0.0, end: 5.0, speaker: "SPEAKER_1")]

        XCTAssertEqual(SpeakerNamingView.sampleCandidates(for: "SPEAKER_0", in: segments).count, 0)
    }

    // MARK: - Playing one

    func testPlayStopsAtTheCap() {
        let long = Seg(start: 100, end: 160, speaker: "SPEAKER_0")
        let short = Seg(start: 100, end: 105, speaker: "SPEAKER_0")

        XCTAssertEqual(SpeakerNamingView.playbackSpan(of: long).end, 100 + SpeakerNamingView.maxSampleSeconds)
        XCTAssertEqual(SpeakerNamingView.playbackSpan(of: short).end, 105)
    }

    func testNextWrapsRoundToTheFirst() {
        XCTAssertEqual(SpeakerNamingView.nextSampleIndex(after: 0, count: 3), 1)
        XCTAssertEqual(SpeakerNamingView.nextSampleIndex(after: 2, count: 3), 0)
        XCTAssertEqual(SpeakerNamingView.nextSampleIndex(after: 0, count: 0), 0)
    }

    func testTheInfoGivesThePlayedLengthAndThePlace() {
        let turn = Seg(start: 10, end: 28, speaker: "SPEAKER_0")
        let long = Seg(start: 10, end: 100, speaker: "SPEAKER_0")

        XCTAssertEqual(SpeakerNamingView.sampleInfo(for: turn, index: 0, count: 6), "18s, 1 of 6")
        XCTAssertEqual(SpeakerNamingView.sampleInfo(for: long, index: 2, count: 6), "20s, 3 of 6", "the capped length")
    }
}
