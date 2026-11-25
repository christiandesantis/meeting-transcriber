import Foundation

/// Which stretches of a speaker the naming dialog can play, and in what order.
///
/// A diarizer segment is often only a second or two, so playing one segment
/// cut most speakers off mid-sentence. A turn joins one speaker's segments
/// across the short pauses inside a sentence, and the dialog steps through the
/// turns best first.
extension SpeakerNamingView {
    typealias Segment = PipelineQueue.SpeakerNamingData.Segment

    /// The longest stretch Play plays of a candidate. Long enough for a full
    /// sentence or two, short enough that hearing a speaker stays quick.
    static let maxSampleSeconds: TimeInterval = 20

    /// `label`'s segments in time order, with each run of them joined into one
    /// turn where the pause between two is under `maxGap` and no other
    /// speaker's segment falls in it. Overlapping segments of `label` always
    /// join.
    static func speakerTurns(
        for label: String, in segments: [Segment], maxGap: TimeInterval = 1.0,
    ) -> [Segment] {
        let own = segments.filter { $0.speaker == label }.sorted { $0.start < $1.start }
        let others = segments.filter { $0.speaker != label }
        var turns: [Segment] = []
        for segment in own {
            guard let last = turns.last else {
                turns.append(segment)
                continue
            }
            let gap = segment.start - last.end
            let interrupted = others.contains { $0.start < segment.start && last.end < $0.end }
            if gap <= 0 || (gap < maxGap && !interrupted) {
                turns[turns.count - 1] = Segment(start: last.start, end: max(last.end, segment.end), speaker: label)
            } else {
                turns.append(segment)
            }
        }
        return turns
    }

    /// `label`'s turns, best sample first: the pure ones (at least
    /// `minDuration` long, no other speaker within `purityWindow` of them) by
    /// length, then all the others by length. Empty when the speaker has no
    /// segments. Its first element is what `selectSampleSegment` picks.
    static func sampleCandidates(
        for label: String,
        in segments: [Segment],
        minDuration: TimeInterval = 1.5,
        purityWindow: TimeInterval = 0.5,
    ) -> [Segment] {
        let others = segments.filter { $0.speaker != label }
        let byLength: (Segment, Segment) -> Bool = { ($0.end - $0.start) > ($1.end - $1.start) }
        var pure: [Segment] = []
        var rest: [Segment] = []
        for turn in speakerTurns(for: label, in: segments) {
            let isPure = (turn.end - turn.start) >= minDuration
                && !others.contains { $0.start < turn.end + purityWindow && turn.start - purityWindow < $0.end }
            if isPure { pure.append(turn) } else { rest.append(turn) }
        }
        return pure.sorted(by: byLength) + rest.sorted(by: byLength)
    }

    /// The part of `candidate` Play plays: its start, for at most
    /// `maxSampleSeconds`.
    static func playbackSpan(of candidate: Segment) -> Segment {
        Segment(
            start: candidate.start,
            end: min(candidate.end, candidate.start + maxSampleSeconds),
            speaker: candidate.speaker,
        )
    }

    /// The candidate after `index` among `count`, back to the first after the last.
    static func nextSampleIndex(after index: Int, count: Int) -> Int {
        count > 0 ? (index + 1) % count : 0
    }

    /// What the row says about the sample Play plays, such as "18s, 1 of 6":
    /// the length played, so it is not mistaken for the speaker's total.
    static func sampleInfo(for candidate: Segment, index: Int, count: Int) -> String {
        let span = playbackSpan(of: candidate)
        return "\(formattedTime(span.end - span.start)), \(index + 1) of \(count)"
    }
}

/// Each speaker's sample candidates for one naming presentation, worked out
/// once: the row reads them on every render, and a long meeting has thousands
/// of segments. A cache, not view state, so nothing observes it.
@MainActor
final class SampleCandidateCache {
    private var revision: UUID?
    private var byLabel: [String: [SpeakerNamingView.Segment]] = [:]

    func candidates(for label: String, in data: PipelineQueue.SpeakerNamingData) -> [SpeakerNamingView.Segment] {
        if revision != data.revision {
            revision = data.revision
            byLabel = [:]
        }
        if let cached = byLabel[label] { return cached }
        let computed = SpeakerNamingView.sampleCandidates(for: label, in: data.segments)
        byLabel[label] = computed
        return computed
    }
}
