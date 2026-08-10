import Foundation

/// Cursor exposes usage through the same web session the browser holds, so the
/// credential path is the browser-cookie import already used for Qwen.
///
/// `GET https://cursor.com/api/usage-summary` returns the billing cycle plus
/// per-bucket spend. All monetary values are **cents**, and `totalPercentUsed`
/// is already a percentage.
struct CursorProvider: UsageProvider {
    let id = "cursor"
    let displayName = "Cursor"
    var cookieOverride: String?
    var userInitiated = false

    static let cookieDomains = ["cursor.com"]
    /// The WorkOS session cookie is what actually authenticates the API.
    static let requiredCookies = ["WorkosCursorSessionToken"]

    private static let usageSummaryURL = "https://cursor.com/api/usage-summary"

    func fetch() async -> ProviderResult {
        let cookie: String
        switch await Self.resolveCookie(override: cookieOverride, allowInteraction: userInitiated) {
        case .resolved(let header, _):
            cookie = header
        case .missing(let message):
            return .needsSetup(message)
        }

        guard let url = URL(string: Self.usageSummaryURL) else {
            return .error(S.internalURLError.s)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch response.httpStatus {
            case 200:
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .error(S.parseFailed("Cursor"))
                }
                return Self.parse(json)
            case 401, 403:
                return .needsSetup(CursorLocalAuth.isInstalled
                    ? S.cursorSessionExpiredApp.s : S.cursorSessionExpiredWeb.s)
            default:
                return .error(S.apiError("Cursor", status: response.httpStatus))
            }
        } catch {
            return .error(S.networkError(error.localizedDescription))
        }
    }

    static func resolveCookie(
        override: String? = nil,
        allowInteraction: Bool = false
    ) async -> CookieResolution {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .resolved(header: override.trimmingCharacters(in: .whitespacesAndNewlines), label: S.sourceManualEntry.s)
        }
        // Check the cache before touching disk: reading Cursor's session means
        // copying its ~2 MB database, and a routine poll has no reason to redo
        // that every few minutes.
        if !allowInteraction, let cached = await BrowserSessionCache.shared.header(for: "cursor") {
            return .resolved(header: cached.header, label: cached.label)
        }
        // Cursor.app's own session beats the browser: no Keychain approval, and it
        // works regardless of which browser the user uses — or whether they ever
        // signed in to cursor.com in one.
        if let local = CursorLocalAuth.session(), !local.isExpired {
            await BrowserSessionCache.shared.store(
                header: local.cookieHeader, label: S.sourceCursorApp.s, for: "cursor"
            )
            return .resolved(header: local.cookieHeader, label: S.sourceCursorApp.s)
        }
        let imported = await BrowserCookies.importSessionAsync(
            domains: cookieDomains,
            requiredCookies: requiredCookies,
            allowInteraction: allowInteraction,
            timeout: allowInteraction ? 45 : 20
        )
        switch imported {
        case .success(let session):
            await BrowserSessionCache.shared.store(
                header: session.cookieHeader, label: session.sourceLabel, for: "cursor"
            )
            Keychain.save(session.cookieHeader, account: Keys.cursorCookieAuto)
            return .resolved(header: session.cookieHeader, label: session.sourceLabel)
        case .failure(let error):
            let lastGood = (await Keychain.loadAsync(Keys.cursorCookieAuto, allowInteraction: allowInteraction) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !lastGood.isEmpty {
                return .resolved(header: lastGood, label: S.sourceStoredAuto.s)
            }
            if case .keychainDenied = error {
                return .missing(S.qwenNeedBrowserAccess.s)
            }
            if case .noMatchingCookies = error {
                return .missing(CursorLocalAuth.isInstalled
                    ? S.cursorNotSignedInApp.s : S.cursorNotSignedInWeb.s)
            }
            return .missing(error.errorDescription ?? S.cursorCookieFailed.s)
        }
    }

    // MARK: - Parsing

    static func parse(_ json: [String: Any]) -> ProviderResult {
        let planName = planDisplay(json["membershipType"] as? String)
        let resetsAt = DateParse.parse(json["billingCycleEnd"])
        let individual = json["individualUsage"] as? [String: Any]

        var windows: [UsageWindow] = []

        // `limit: 0` is a Free plan with no included quota; a 0% bar would imply
        // headroom that does not exist.
        if let plan = individual?["plan"] as? [String: Any], enabled(plan), num(plan["limit"]) ?? 0 > 0 {
            // Prefer the percentage Cursor computes; fall back to used/limit.
            let percent = num(plan["totalPercentUsed"]) ?? ratio(used: plan["used"], limit: plan["limit"])
            if let percent {
                windows.append(UsageWindow(
                    name: S.windowPlan.s, percent: clamp(percent), resetsAt: resetsAt,
                    detail: money(used: plan["used"], limit: plan["limit"])
                ))
            }
        }

        // On-demand spend has no cap when `limit` is absent, so a percentage would
        // be meaningless; show it only when Cursor reports a ceiling.
        if let onDemand = individual?["onDemand"] as? [String: Any], enabled(onDemand),
           let percent = ratio(used: onDemand["used"], limit: onDemand["limit"]) {
            windows.append(UsageWindow(
                name: S.windowOnDemand.s, percent: clamp(percent), resetsAt: resetsAt,
                detail: money(used: onDemand["used"], limit: onDemand["limit"])
            ))
        }

        // Team members get a personal cap under `overall` instead of `plan`.
        if windows.isEmpty, let overall = individual?["overall"] as? [String: Any],
           let percent = ratio(used: overall["used"], limit: overall["limit"]) {
            windows.append(UsageWindow(
                name: S.windowPersonalCap.s, percent: clamp(percent), resetsAt: resetsAt,
                detail: money(used: overall["used"], limit: overall["limit"])
            ))
        }

        let note = costNote(json)
        guard !windows.isEmpty else {
            // A Free plan reports `limit: 0`, which is not an error — there is
            // simply no included quota to chart.
            // A plan name alone is not enough: a response with no usage block at
            // all is a contract change worth surfacing, not a Free plan.
            if json["isUnlimited"] as? Bool == true || note != nil {
                return .ok(planName: planName, windows: [], limitReached: false, note: note)
            }
            return .error(S.cursorNoUsage.s)
        }
        return .ok(planName: planName, windows: windows,
                   limitReached: windows.contains { $0.percent >= 100 }, note: note)
    }

    /// On-demand spend with no ceiling cannot be a percentage, so it would
    /// otherwise vanish entirely — yet it is the number that actually costs money.
    static func costNote(_ json: [String: Any]) -> String? {
        let individual = json["individualUsage"] as? [String: Any]
        if let onDemand = individual?["onDemand"] as? [String: Any], enabled(onDemand),
           num(onDemand["limit"]) == nil, let used = num(onDemand["used"]), used > 0 {
            return S.onDemandUncapped(money(used: used, limit: nil) ?? "")
        }
        if let plan = individual?["plan"] as? [String: Any],
           num(plan["limit"]) == 0, num(plan["used"]) == 0 {
            return S.cursorNoIncludedUsage.s
        }
        return nil
    }

    private static func enabled(_ bucket: [String: Any]) -> Bool {
        (bucket["enabled"] as? NSNumber)?.boolValue ?? true
    }

    private static func ratio(used: Any?, limit: Any?) -> Double? {
        guard let used = num(used), let limit = num(limit), limit > 0 else { return nil }
        return used / limit * 100
    }

    private static func clamp(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(100, max(0, percent))
    }

    /// Cursor reports money in cents.
    static func money(used: Any?, limit: Any?) -> String? {
        guard let used = num(used) else { return nil }
        guard let limit = num(limit), limit > 0 else { return dollars(used) }
        return "\(dollars(used)) / \(dollars(limit))"
    }

    private static func dollars(_ cents: Double) -> String {
        let value = cents / 100
        return value == value.rounded()
            ? String(format: "$%.0f", value)
            : String(format: "$%.2f", value)
    }

    static func planDisplay(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "free_trial": return "Free Trial"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "business", "team": return "Business"
        case "enterprise": return "Enterprise"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
