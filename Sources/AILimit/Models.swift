import Foundation

struct UsageWindow: Codable, Equatable {
    var name: String
    var percent: Double
    var resetsAt: Date?
    /// Optional secondary line, e.g. `3.5M / 20M` token totals.
    var detail: String?
}

struct ProviderSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var planName: String?
    var windows: [UsageWindow]
    var fetchedAt: Date
    var errorMessage: String?
    var needsSetup: Bool
    var limitReached: Bool
    /// Money/credit facts that are not a percentage — extra-usage balances,
    /// uncapped spend, add-on packs. Shown as one line under the bars.
    var note: String?

    var isOK: Bool { errorMessage == nil && !needsSetup }
    var worstPercent: Double { windows.map(\.percent).max() ?? 0 }
}

enum Severity {
    case ok, warn, critical

    static func of(_ percent: Double) -> Severity {
        if percent >= 85 { return .critical }
        if percent >= 50 { return .warn }
        return .ok
    }
}
