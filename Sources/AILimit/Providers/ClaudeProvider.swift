import Foundation
import Security

/// Claude Code's OAuth credentials, wherever they currently live.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let source: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // Treat "about to expire" as expired; a request in flight would fail anyway.
        return expiresAt.timeIntervalSinceNow < 60
    }

    /// Claude Code keeps the live credentials in the login Keychain and only
    /// sometimes mirrors them to `~/.claude/.credentials.json`. Reading the file
    /// first is how this app ended up hammering the API with a token that had
    /// expired days earlier, so the Keychain is authoritative here.
    static func load(allowInteraction: Bool = false) -> ClaudeCredentials? {
        keychain(allowInteraction: allowInteraction) ?? file()
    }

    /// Bounded variant used on the refresh path so a pending approval dialog can
    /// never wedge the app; falls back to the on-disk mirror on timeout.
    static func loadAsync(allowInteraction: Bool) async -> ClaudeCredentials? {
        let timeout: TimeInterval = allowInteraction ? 30 : 10
        let fromKeychain = await Keychain.bounded(timeout: timeout) {
            keychain(allowInteraction: allowInteraction)
        }
        return fromKeychain ?? file()
    }

    static func keychain(allowInteraction: Bool = false) -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Never prompt on a background refresh; fall through to the file instead.
        // An explicit refresh may prompt, which is the only way the user can
        // grant this app access to Claude Code's Keychain item.
        return Keychain.withInteraction(allowInteraction) {
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return parse(data, source: "Keychain")
        }
    }

    static func file() -> ClaudeCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, source: "credentials.json")
    }

    static func parse(_ data: Data, source: String) -> ClaudeCredentials? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: DateParse.parse(oauth["expiresAt"]),
            subscriptionType: (oauth["subscriptionType"] as? String)
                ?? (oauth["rateLimitTier"] as? String),
            source: source
        )
    }
}

/// Anthropic throttles repeated failing calls to the usage endpoint hard — a
/// single stale token earned a `Retry-After: 2703`. Once told to back off, stop
/// polling until the window passes; only an explicit user refresh may probe.
enum ClaudeRateLimitGate {
    private static let keyPrefix = "claudeUsageBlockedUntil."

    private static func key(for token: String) -> String {
        keyPrefix + String(format: "%016llx", UInt64(bitPattern: Int64(token.hashValue)))
    }

    static func blockedUntil(token: String, now: Date = Date()) -> Date? {
        let raw = UserDefaults.standard.object(forKey: key(for: token)) as? Double
        guard let raw else { return nil }
        let until = Date(timeIntervalSince1970: raw)
        guard until > now else {
            UserDefaults.standard.removeObject(forKey: key(for: token))
            return nil
        }
        return until
    }

    static func record(token: String, retryAfter: Date?, now: Date = Date()) {
        let until = (retryAfter.map { $0 > now ? $0 : nil } ?? nil) ?? now.addingTimeInterval(300)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: key(for: token))
    }

    static func clear(token: String) {
        UserDefaults.standard.removeObject(forKey: key(for: token))
    }

    static func parseRetryAfter(_ header: String?, now: Date = Date()) -> Date? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }
}

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"
    /// Manual refreshes are allowed to probe through an active backoff window.
    var userInitiated = false

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    func fetch() async -> ProviderResult {
        guard let credentials = await ClaudeCredentials.loadAsync(allowInteraction: userInitiated) else {
            return .needsSetup(S.claudeNoCredentials.s)
        }

        // Sending a known-expired token is what triggered the throttling, so stop here.
        guard !credentials.isExpired else {
            return .needsSetup(S.claudeExpired.s)
        }
        if !userInitiated, let until = ClaudeRateLimitGate.blockedUntil(token: credentials.accessToken) {
            return .error(S.claudeRateLimited(RelativeTime.resetText(until)))
        }

        var request = URLRequest(url: URL(string: Self.usageURL)!, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Identifying as Claude Code keeps us in the same throttling bucket as the
        // CLI; an unknown agent gets a 429 where the CLI gets an actionable 401.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let object: [String: Any]
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            switch response.httpStatus {
            case 200:
                ClaudeRateLimitGate.clear(token: credentials.accessToken)
                guard let parsed = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
                    return .error(S.parseFailed("Claude"))
                }
                object = parsed
            case 401, 403:
                return .needsSetup(S.claudeAuthExpired.s)
            case 429:
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let retryAfter = ClaudeRateLimitGate.parseRetryAfter(header)
                ClaudeRateLimitGate.record(token: credentials.accessToken, retryAfter: retryAfter)
                let when = retryAfter.map { RelativeTime.resetText($0) } ?? S.rateLimitSoon.s
                return .error(S.claudeRateLimited(when))
            default:
                return .error(S.apiError("Claude", status: response.httpStatus))
            }
        } catch {
            return .error(S.networkError(error.localizedDescription))
        }

        let windows = Self.parseWindows(object)
        guard !windows.isEmpty else {
            return .error(S.claudeNoUsage.s)
        }
        return .ok(
            planName: Self.planDisplay(credentials.subscriptionType),
            windows: windows,
            limitReached: windows.contains { $0.percent >= 100 },
            note: Self.costNote(object)
        )
    }

    static func parseWindows(_ object: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let fiveHour = object["five_hour"] as? [String: Any], let utilization = num(fiveHour["utilization"]) {
            windows.append(UsageWindow(name: S.windowFiveHour.s, percent: utilization, resetsAt: DateParse.parse(fiveHour["resets_at"])))
        }
        if let sevenDay = object["seven_day"] as? [String: Any], let utilization = num(sevenDay["utilization"]) {
            windows.append(UsageWindow(name: S.windowWeekly.s, percent: utilization, resetsAt: DateParse.parse(sevenDay["resets_at"])))
        }
        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits where limit["kind"] as? String == "weekly_scoped" {
                guard let percent = num(limit["percent"]) else { continue }
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let name = model.map { S.weeklyScoped($0) } ?? S.weeklyScopedFallback.s
                windows.append(UsageWindow(name: name, percent: percent, resetsAt: DateParse.parse(limit["resets_at"])))
            }
        }
        return windows
    }

    /// Anthropic reports plan-overflow credits separately from the rate windows.
    /// It is only worth a line when the user actually turned it on — otherwise
    /// every card would carry a permanent "extra usage: off".
    static func costNote(_ object: [String: Any]) -> String? {
        if let extra = object["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? NSNumber)?.boolValue == true {
            let used = num(extra["used_credits"])
            let limit = num(extra["monthly_limit"])
            if let used, let limit, limit > 0 {
                return S.extraUsageCredits(NumberFormat.compact(used), NumberFormat.compact(limit))
            }
            if let utilization = num(extra["utilization"]) {
                return S.extraUsagePercent(Int(utilization.rounded()))
            }
            return S.extraUsageOn.s
        }
        if let spend = object["spend"] as? [String: Any],
           (spend["enabled"] as? NSNumber)?.boolValue == true,
           let used = (spend["used"] as? [String: Any]),
           let minor = num(used["amount_minor"]), minor > 0 {
            let exponent = num(used["exponent"]) ?? 2
            let amount = minor / pow(10, exponent)
            let currency = (used["currency"] as? String) ?? "USD"
            return S.creditsSpent(String(format: "%@%.2f", currency == "USD" ? "$" : "", amount))
        }
        return nil
    }

    /// `subscriptionType` rides along in the credentials, so the extra
    /// `/api/oauth/profile` round trip this used to make is unnecessary — that
    /// halves the request count against a rate-limited endpoint.
    static func planDisplay(_ raw: String?) -> String? {
        guard var value = raw?.lowercased(), !value.isEmpty else { return nil }
        for prefix in ["default_claude_", "claude_"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let userAgent: String = "claude-code/\(detectVersion() ?? "2.1.0")"

    /// Reads the version Claude Code already recorded on disk rather than paying
    /// for a `claude --version` process spawn on every refresh.
    static func detectVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let updateResult = home.appendingPathComponent(".claude/.last-update-result.json")
        if let data = try? Data(contentsOf: updateResult),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = json["version_to"] as? String, !version.isEmpty {
            return version
        }
        let versionsDir = home.appendingPathComponent(".local/share/claude/versions")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path) {
            return entries
                .filter { $0.first?.isNumber == true }
                .max { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        return nil
    }
}
