import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The recording side of the per-app output folders (`AppOutputFolders`): which
/// folder a finished recording is assigned, and the refusal to record while
/// the main output folder overlaps one of them. Split out of `WatchLoop.swift`
/// to keep that file under the line cap.
extension WatchLoop {
    static let outputConflictTitle = "Recording Blocked"

    /// The folder a recording carried under `appName` is assigned, or nil for
    /// the main output folder.
    ///
    /// Decided here, when the recording is handed on, and stored with it: the
    /// pipeline job keeps it for every later write, the record-only path writes
    /// into it at once. A microphone-only recording is never routed, whatever
    /// the map holds, because "Microphone" names no app.
    func assignedOutputFolder(forApp appName: String) -> URL? {
        guard appName != ManualRecordingInfo.microphoneAppName else { return nil }
        return outputFolders().folder(forApp: appName)
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
