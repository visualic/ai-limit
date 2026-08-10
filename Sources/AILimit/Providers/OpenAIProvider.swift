import Foundation

struct OpenAIProvider: UsageProvider {
    let id = "openai"
    let displayName = "OpenAI Codex"

    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let refreshURL = "https://auth.openai.com/oauth/token"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    func fetch() async -> ProviderResult {
        guard let data = try? Data(contentsOf: authURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              var accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            return .needsSetup(S.openAINoCredentials.s)
        }
        let refreshToken = tokens["refresh_token"] as? String

        if isExpired(accessToken) {
            if let refreshToken, let renewed = await refreshAccessToken(refreshToken) {
                accessToken = renewed
            } else {
                return .error(S.openAIRefreshFailed.s)
            }
        }

        var request = URLRequest(url: URL(string: Self.usageURL)!, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard response.httpStatus == 200 else {
                if response.httpStatus == 401 || response.httpStatus == 403 {
                    return .error(S.openAIAuthExpired.s)
                }
                return .error(S.apiError("OpenAI", status: response.httpStatus))
            }
            guard let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
                return .error(S.parseFailed("OpenAI"))
            }
            return parseUsage(object)
        } catch {
            return .error(S.networkError(error.localizedDescription))
        }
    }

    private func parseUsage(_ object: [String: Any]) -> ProviderResult {
        let planName = Self.planDisplay(object["plan_type"] as? String ?? "")

        var windows: [UsageWindow] = []
        var limitReached = false
        if let rateLimit = object["rate_limit"] as? [String: Any] {
            limitReached = rateLimit["limit_reached"] as? Bool ?? false
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                windows.append(Self.window(from: primary))
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                windows.append(Self.window(from: secondary))
            }
        }
        if let additional = object["additional_rate_limits"] as? [[String: Any]] {
            for item in additional {
                guard let name = item["limit_name"] as? String,
                      let rateLimit = item["rate_limit"] as? [String: Any],
                      let primary = rateLimit["primary_window"] as? [String: Any],
                      let percent = num(primary["used_percent"]),
                      percent > 0 else { continue }
                var window = Self.window(from: primary)
                window.name = name
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            return .error(S.openAINoUsage.s)
        }
        return .ok(planName: planName, windows: windows, limitReached: limitReached,
                   note: Self.costNote(object))
    }

    /// Codex credits top up a spent quota, so the balance matters most exactly
    /// when the weekly window is exhausted. Only shown when there is one.
    static func costNote(_ object: [String: Any]) -> String? {
        guard let credits = object["credits"] as? [String: Any] else { return nil }
        if (credits["unlimited"] as? NSNumber)?.boolValue == true { return S.creditsUnlimited.s }
        if let balance = num(credits["balance"]), balance > 0 {
            return S.creditsLeft(NumberFormat.compact(balance))
        }
        if (credits["has_credits"] as? NSNumber)?.boolValue == true { return S.creditsAvailable.s }
        return nil
    }

    private static func window(from raw: [String: Any]) -> UsageWindow {
        let percent = num(raw["used_percent"]) ?? 0
        let windowSeconds = num(raw["limit_window_seconds"]).map { Int($0) }
        var resetsAt: Date?
        if let resetAt = num(raw["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: resetAt)
        } else if let resetAfter = num(raw["reset_after_seconds"]) {
            resetsAt = Date(timeIntervalSinceNow: resetAfter)
        }
        return UsageWindow(name: windowName(seconds: windowSeconds), percent: percent, resetsAt: resetsAt)
    }

    private static func windowName(seconds: Int?) -> String {
        guard let seconds else { return S.windowGeneric.s }
        switch seconds {
        case ..<21_600: return S.windowFiveHour.s
        case ..<172_800: return S.hourWindow(seconds / 3600)
        case ..<691_200: return S.windowWeekly.s
        default: return S.dayWindow(seconds / 86_400)
        }
    }

    private static func planDisplay(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "": return nil
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return raw.capitalized
        }
    }

    private func isExpired(_ token: String) -> Bool {
        guard let expiration = jwtExp(token) else { return false }
        return expiration.timeIntervalSinceNow < 300
    }

    private func jwtExp(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = num(payload["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func refreshAccessToken(_ refreshToken: String) async -> String? {
        var request = URLRequest(url: URL(string: Self.refreshURL)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode([
            ("client_id", Self.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]).utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              response.httpStatus == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = object["access_token"] as? String,
              !token.isEmpty else { return nil }
        return token
    }
}
