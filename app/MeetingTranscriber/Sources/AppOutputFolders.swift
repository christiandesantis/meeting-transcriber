import Foundation

/// Output folders chosen per meeting app, so that calls from different apps
/// (a work browser and a personal one, say) never share a folder on disk.
///
/// Read from the hidden `outputFolderByApp` default, which has no Settings
/// control of its own:
///
///     defaults write <bundle id> outputFolderByApp -dict \
///         "Google Chrome Beta" "/Users/me/Meetings" "Google Chrome" "~/Meetings-personal"
///
/// A key is the exact, case-sensitive name a recording is carried under
/// (`PipelineJob.appName`): the app name for a native client ("Microsoft
/// Teams", "Zoom", "Webex") and the browser's own process name for a browser
/// call, since `PowerAssertionDetector` carries each browser as itself. A
/// value is an absolute folder, or one starting with `~/`.
///
/// What is not mapped goes to the main output folder: an unmapped app, a
/// microphone-only recording, a file import and a recovered orphan.
///
/// Always empty in the App Store build, where a sandboxed app could not write
/// to a path it was never handed.
struct AppOutputFolders: Equatable {
    static let defaultsKey = "outputFolderByApp"
    static let empty = Self(folders: [:])

    let folders: [String: URL] // app name to its standardized absolute folder
    let unusableApps: [String] // entries whose value is not a folder this can use, sorted

    init(folders: [String: URL], unusableApps: [String] = []) {
        self.folders = folders
        self.unusableApps = unusableApps.sorted()
    }

    /// Parse what `defaults write -dict` stores: a dictionary of strings.
    ///
    /// An entry that cannot be used (an empty name, a value that is not a
    /// string, a relative path) is kept as unusable rather than dropped,
    /// because dropping it would send that app's calls to the main folder,
    /// which is exactly what the entry was written to prevent. A value that is
    /// not a dictionary at all is unusable as a whole, under the key's name.
    init(defaultsValue: Any?, home: URL) {
        guard let value = defaultsValue else {
            self.init(folders: [:])
            return
        }
        guard let entries = value as? [String: Any] else {
            self.init(folders: [:], unusableApps: [Self.defaultsKey])
            return
        }
        var folders: [String: URL] = [:]
        var unusable: [String] = []
        for (app, raw) in entries {
            if !app.isEmpty, let raw = raw as? String, let folder = Self.folder(fromSetting: raw, home: home) {
                folders[app] = folder
            } else {
                unusable.append(app)
            }
        }
        self.init(folders: folders, unusableApps: unusable)
    }

    var isEmpty: Bool {
        folders.isEmpty && unusableApps.isEmpty
    }

    /// The folder for a recording carried under `appName`, or nil for the main
    /// output folder. Exact and case-sensitive, like the names themselves.
    func folder(forApp appName: String) -> URL? {
        folders[appName]
    }

    /// The first reason, in app-name order, that recording must stay off with
    /// this map and `mainFolder` as the main output folder; nil when there is
    /// none.
    ///
    /// The main folder may not equal, contain or sit inside any mapped folder:
    /// anything that reads or syncs one of them would otherwise also see the
    /// other's meetings. Two apps sharing one mapped folder is allowed, since
    /// that is a choice the map states outright.
    func conflict(withMainFolder mainFolder: URL) -> Conflict? {
        if let app = unusableApps.first {
            return Conflict(appName: app, appFolder: nil, mainFolder: mainFolder, overlap: .unusableFolder)
        }
        let main = Self.comparablePath(mainFolder)
        for (app, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let mapped = Self.comparablePath(folder)
            let overlap: Overlap? = if main == mapped {
                .sameFolder
            } else if main.starts(with: mapped) {
                .mainInsideAppFolder
            } else if mapped.starts(with: main) {
                .mainContainsAppFolder
            } else {
                nil
            }
            if let overlap {
                return Conflict(appName: app, appFolder: folder, mainFolder: mainFolder, overlap: overlap)
            }
        }
        return nil
    }

    /// How a per-app folder and the main output folder collide.
    enum Overlap: Equatable {
        case sameFolder
        case mainInsideAppFolder
        case mainContainsAppFolder
        case unusableFolder // the entry names no absolute folder
    }

    /// Why recording is refused, worded for the notification that says so.
    struct Conflict: LocalizedError, Equatable {
        let appName: String
        let appFolder: URL? // nil for an unusable entry
        let mainFolder: URL
        let overlap: Overlap

        var errorDescription: String? {
            message
        }

        var message: String {
            let fix = "Choose a main output folder outside every per-app folder in Settings, Output."
            let main = mainFolder.path
            let app = appFolder?.path ?? ""
            switch overlap {
            case .sameFolder:
                return "Recording is off: the main output folder \(main) is also the folder for \(appName). \(fix)"

            case .mainInsideAppFolder:
                return "Recording is off: the main output folder \(main) is inside the folder for \(appName), \(app). \(fix)"

            case .mainContainsAppFolder:
                return "Recording is off: the main output folder \(main) contains the folder for \(appName), \(app). \(fix)"

            case .unusableFolder where appName == AppOutputFolders.defaultsKey:
                return "Recording is off: the \(appName) setting is not a list of app names and folders. Rewrite it with defaults write."

            case .unusableFolder:
                return "Recording is off: the output folder set for \(appName) is not an absolute path. Rewrite it with defaults write."
            }
        }
    }

    // MARK: - Paths

    /// `raw` as a standardized folder URL, with a leading `~` taken as `home`;
    /// nil unless it ends up absolute.
    static func folder(fromSetting raw: String, home: URL) -> URL? {
        let path = if raw == "~" {
            home.path
        } else if raw.hasPrefix("~/") {
            home.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            raw
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The path components the overlap check compares: symlinks and `.`/`..`
    /// resolved, and lowercased, because the default macOS volume ignores case
    /// and a guard should refuse too often rather than too rarely.
    private static func comparablePath(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
    }
}
