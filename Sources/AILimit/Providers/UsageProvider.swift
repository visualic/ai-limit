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
