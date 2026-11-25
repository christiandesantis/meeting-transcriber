import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The recording side of the per-app output folders (`AppOutputFolders`): which
/// folder a recording is assigned, the start sidecar that keeps it for crash
/// recovery, and the refusal to record while the main output folder overlaps
/// one of them. Split out of `WatchLoop.swift` to keep that file under the
/// line cap.
extension WatchLoop {
    static let outputConflictTitle = "Recording Blocked"

    /// The folder a recording carried under `appName` is assigned, or nil for
    /// the main output folder.
    ///
    /// Decided when the recording starts, for its start sidecar, and again
    /// when it is handed on, where it is stored with it: the pipeline job keeps
    /// it for every later write, the record-only path writes into it at once.
    func assignedOutputFolder(forApp appName: String) -> URL? {
        outputFolders().assignedFolder(forRecordingFrom: appName)
    }

    /// Save what this recording was started for beside its tracks, so a crash
    /// recovery can route it (see `RecordingStartSidecar`). Nothing for a
    /// recorder that reports no staging stem.
    func writeStartSidecar(for recorder: any RecordingProvider, appName: String, title: String) {
        guard let staging = recorder.stagingStem else { return }
        RecordingStartSidecar(
            stem: staging.stem, appName: appName, title: title,
            assignedOutputDir: assignedOutputFolder(forApp: appName),
        ).write(in: staging.directory)
    }

    /// Whether a recording must not start because of the output folders, and
    /// if so, tell the user.
    ///
    /// Asked on every poll that sees a meeting, so the notification goes out
    /// once per distinct refusal: a call that stays refused would otherwise
    /// post one every few seconds. Clearing the refusal re-arms it.
    func refusesRecordingForOutputFolders() -> Bool {
        guard let conflict = outputFolderConflict() else {
            reportedOutputConflict = nil
            return false
        }
        if conflict != reportedOutputConflict {
            reportedOutputConflict = conflict
            logger.error("Recording refused: the main output folder overlaps a per-app output folder")
            notifier.notify(title: Self.outputConflictTitle, body: conflict.message, urgency: .timeSensitive)
        }
        return true
    }
}
