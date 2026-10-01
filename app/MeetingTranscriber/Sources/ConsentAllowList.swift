import Foundation

/// Apps the user answered "Always for this app" about, so a meeting detected in
/// them records without the browser-meeting consent prompt. The mirror image of
/// `ConsentDenyList`, and built the same way so the two cannot drift apart.
///
/// This is the positive state the deny list left room for: it exists because it
/// now carries behaviour, skipping the per-meeting question. The cost is the one
/// the prompt was guarding against, that the WebRTC assertion is not
/// meeting-exclusive, so an always-app records any WebRTC use, including a Meet
/// page that was never joined. That is why it is opt-in per app, only reachable
/// by answering a prompt about that app, and reviewable in Settings.
///
/// The deny list wins if an app is somehow on both: `BrowserConsentPolicy`
/// checks the denial first, and the detector drops denied identities before
/// they reach the gate at all.
///
/// Entries are process names exactly as the power assertion reports them, and
/// they are matched exactly, for the same reason as the deny list: a looser rule
/// would record an app the user was never asked about.
struct ConsentAllowList: Equatable {
    /// Insertion-ordered, so the Settings rows do not reshuffle between renders.
    private(set) var allowed: [String]

    init(allowed: [String] = []) {
        self.allowed = allowed
    }

    func isAllowed(_ app: String) -> Bool {
        allowed.contains(app)
    }

    /// Idempotent, like `ConsentDenyList.denying`.
    func allowing(_ app: String) -> Self {
        guard !allowed.contains(app) else { return self }
        return Self(allowed: allowed + [app])
    }

    /// The Settings "Remove" action. A no-op for an app that is not listed, so a
    /// stale view cannot corrupt the list.
    func reverting(_ app: String) -> Self {
        Self(allowed: allowed.filter { $0 != app })
    }
}

/// Read/write access to the allow list, injected into `WatchLoop` the same way
/// as `ConsentDenyListStoring` and main-actor isolated for the same reasons.
@MainActor
protocol ConsentAllowListStoring: AnyObject {
    var allowList: ConsentAllowList { get set }
}

extension ConsentAllowListStoring {
    func isAllowed(_ app: String) -> Bool {
        allowList.isAllowed(app)
    }

    func allow(_ app: String) {
        allowList = allowList.allowing(app)
    }

    func revert(_ app: String) {
        allowList = allowList.reverting(app)
    }
}

/// Default for tests and for any `WatchLoop` built without an explicit store.
final class InMemoryConsentAllowListStore: ConsentAllowListStoring {
    var allowList: ConsentAllowList

    init(allowList: ConsentAllowList = ConsentAllowList()) {
        self.allowList = allowList
    }
}

/// The persisting store, backed by `AppSettings.consentAllowedApps`. Round-tripped
/// against a real defaults suite in `ConsentAllowListStoreTests`, since every
/// other test injects the in-memory store.
@MainActor
final class ConsentAllowListStore: ConsentAllowListStoring {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var allowList: ConsentAllowList {
        get { ConsentAllowList(allowed: settings.consentAllowedApps) }
        set { settings.consentAllowedApps = newValue.allowed }
    }
}
