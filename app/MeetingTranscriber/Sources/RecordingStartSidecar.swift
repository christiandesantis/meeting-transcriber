import Foundation

/// What is known about a recording the moment it starts, on disk beside its
/// tracks in staging: the app it was carried under, its title and the
/// per-app folder it was assigned.
///
/// The app name otherwise reaches disk only when the stopped recording is
/// handed on, so a recording whose process died mid-meeting came back from
/// crash recovery as an "Unknown" app in the main output folder, whatever the
/// per-app map said. Removed once the recording is handed on normally; a
/// recovered one keeps it until its audio leaves staging, like `MicMuteLog`.
struct RecordingStartSidecar: Codable, Equatable {
    let stem: String
    let appName: String
    let title: String
    let assignedOutputDir: URL? // nil for the main output folder

    static func url(stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(stem + RecordingFileSuffix.startInfo)
    }

    /// Best effort and owner-only, like the tracks it describes: a failed write
    /// costs only the routing of a recording that later crashes.
    func write(in dir: URL) {
        let file = Self.url(stem: stem, in: dir)
        guard let data = try? JSONEncoder().encode(self),
              (try? data.write(to: file, options: .atomic)) != nil else { return }

        try? FileManager.default.restrictToOwner(file)
    }

    /// The sidecar of `stem` in `dir`, or nil when there is none, it does not
    /// decode, or it names another stem.
    static func read(stem: String, in dir: URL) -> Self? {
        guard let data = try? Data(contentsOf: url(stem: stem, in: dir)),
              let sidecar = try? JSONDecoder().decode(Self.self, from: data),
              sidecar.stem == stem else { return nil }

        return sidecar
    }

    static func remove(stem: String, in dir: URL) {
        try? FileManager.default.removeItem(at: url(stem: stem, in: dir))
    }

    /// Remove the sidecar of the recording whose mix is at `mix`, a file named
    /// `<stem>_mix.wav`. Nothing for any other name.
    static func remove(besideMix mix: URL) {
        let name = mix.lastPathComponent
        guard name.hasSuffix(RecordingFileSuffix.mix) else { return }
        remove(stem: String(name.dropLast(RecordingFileSuffix.mix.count)), in: mix.deletingLastPathComponent())
    }

    /// What a recovered recording of `stem` is queued as: the app and title it
    /// was started with, and the folder the per-app map gives that app now.
    ///
    /// The folder is looked up again rather than taken from the sidecar, so a
    /// map edited since the crash applies: an app no longer mapped goes to the
    /// main folder, a remapped one to its new folder. Without a sidecar the
    /// recording is queued as before, unnamed and in the main folder.
    static func recoveredRouting(
        stem: String, sidecar: Self?, folders: AppOutputFolders,
    ) -> (title: String, appName: String, assignedOutputDir: URL?) {
        guard let sidecar else { return ("Recovered Recording (\(stem))", "Unknown", nil) }
        return (sidecar.title, sidecar.appName, folders.assignedFolder(forRecordingFrom: sidecar.appName))
    }
}
