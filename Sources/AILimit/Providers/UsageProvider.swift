import Foundation

enum ProviderResult {
    case ok(planName: String?, windows: [UsageWindow], limitReached: Bool, note: String? = nil)
    case error(String)
    case needsSetup(String)
}

/// Outcome of locating a browser/app session for a cookie-authenticated provider.
/// Shared because more than one provider resolves credentials this way.
enum CookieResolution {
    case resolved(header: String, label: String)
    case missing(String)
}

protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetch() async -> ProviderResult
}

/// A service's identity without the machinery to fetch it — enough for Settings
/// to list a provider that is switched off and therefore never constructed.
struct ProviderInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
}

/// Every service the app knows about, in the order they appear in the popover
/// and the menu bar. One list, so the app and `--check` cannot drift apart.
enum ProviderRoster {
    static func all(userInitiated: Bool = false) -> [UsageProvider] {
        [
            ClaudeProvider(userInitiated: userInitiated),
            OpenAIProvider(),
            CursorProvider(userInitiated: userInitiated),
            QwenProvider(userInitiated: userInitiated),
        ]
    }

    /// Only what the user left switched on. A switched-off service is not
    /// fetched at all, so it costs no request and no credential read.
    static func enabled(userInitiated: Bool = false) -> [UsageProvider] {
        all(userInitiated: userInitiated).filter { ProviderVisibility.isEnabled($0.id) }
    }

    static var listing: [ProviderInfo] {
        all().map { ProviderInfo(id: $0.id, displayName: $0.displayName) }
    }
}

/// Which services the user actually subscribes to.
///
/// Stored as the *disabled* set rather than the enabled one: a service added in a
/// later version then shows up for everybody, instead of staying invisible until
/// they happen to open Settings.
enum ProviderVisibility {
    static var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.disabledProviders) ?? []) }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.disabledProviders)
            } else {
                UserDefaults.standard.set(newValue.sorted(), forKey: Keys.disabledProviders)
            }
        }
    }

    static func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }
}
