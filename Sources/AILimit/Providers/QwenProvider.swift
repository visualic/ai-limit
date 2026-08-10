import Foundation

struct QwenRegionConfig: Sendable {
    let id: String
    let apiHost: String
    let dashboardOrigin: String
    let dashboardURL: String
    let regionID: String
    let action: String
    let consoleSite: String
    let commodityCode: String
    /// Cookie host suffix used when importing a session straight from a browser.
    let cookieDomain: String

    static let intlPersonal = QwenRegionConfig(
        id: "intl-personal",
        apiHost: "https://bailian-singapore-cs.alibabacloud.com",
        dashboardOrigin: "https://modelstudio.console.alibabacloud.com",
        dashboardURL: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan/personal",
        regionID: "ap-southeast-1",
        action: "IntlBroadScopeAspnGateway",
        consoleSite: "MODELSTUDIO_ALBABACLOUD",
        commodityCode: "sfm_tokenplansolo_public_intl",
        cookieDomain: "alibabacloud.com"
    )

    static let cnPersonal = QwenRegionConfig(
        id: "cn-personal",
        apiHost: "https://bailian-cs.console.aliyun.com",
        dashboardOrigin: "https://bailian.console.aliyun.com",
        dashboardURL: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal",
        regionID: "cn-beijing",
        action: "BroadScopeAspnGateway",
        consoleSite: "BAILIAN_ALIYUN",
        commodityCode: "sfm_tokenplansolo_public_cn",
        cookieDomain: "aliyun.com"
    )

    static func current() -> QwenRegionConfig {
        UserDefaults.standard.string(forKey: Keys.qwenRegion) == "cn-personal" ? .cnPersonal : .intlPersonal
    }
}

/// Why the console gateway rejected a call. The distinction matters because the
/// three failures need three different things from the user: nothing (stale
/// sec_token — we just refetch it), a fresh cookie paste (expired session), or
/// a console-side permission change (a fresh cookie would not help).
enum QwenFailure: Error {
    /// The sec_token is stale. Recoverable in-process by re-resolving it.
    case staleToken(String)
    /// The browser session behind the cookie is gone; the user must re-paste.
    case loginRequired(String)
    /// The session is valid but lacks access to the workspace/resource.
    case forbidden(String)
    case api(String)
    case network(String)
    case parse(String)

    var message: String {
        switch self {
        case .staleToken(let text), .loginRequired(let text), .forbidden(let text),
             .api(let text), .network(let text), .parse(let text):
            return text
        }
    }
}

/// Caches the resolved `sec_token` per (region, cookie) so a routine refresh is
/// one POST instead of three requests — resolving it costs a full console HTML
/// page download, which we were repeating on every poll.
actor QwenSecTokenCache {
    static let shared = QwenSecTokenCache()

    private struct Entry {
        let token: String
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 1_800

    func token(for key: String) -> String? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < ttl else {
            entries[key] = nil
            return nil
        }
        return entry.token
    }

    func store(_ token: String, for key: String) {
        entries[key] = Entry(token: token, storedAt: Date())
    }

    func invalidate(_ key: String) {
        entries[key] = nil
    }

    func invalidateAll() {
        entries.removeAll()
    }
}

/// Holds a resolved session header per provider so a routine refresh does not
/// re-read the source. That matters twice over: re-reading a browser profile
/// re-enters the Keychain, and re-reading Cursor's state copies a ~2 MB database.
actor BrowserSessionCache {
    static let shared = BrowserSessionCache()

    private struct Entry {
        let header: String
        let label: String
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 600

    func header(for region: String) -> (header: String, label: String)? {
        guard let entry = entries[region] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < ttl else {
            entries[region] = nil
            return nil
        }
        return (entry.header, entry.label)
    }

    func store(header: String, label: String, for region: String) {
        entries[region] = Entry(header: header, label: label, storedAt: Date())
    }

    func invalidateAll() { entries.removeAll() }
}

struct QwenProvider: UsageProvider {
    let id = "qwen"
    let displayName = "Qwen Token Plan"
    var cookieOverride: String?
    /// An explicit refresh may raise the one-time Keychain approval; a timer tick
    /// must not.
    var userInitiated = false

    /// Cookie names that prove a live Alibaba console session.
    static let requiredCookies = ["login_aliyunid_csrf", "login_aliyunid_ticket"]

    private static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    private static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    private static let quotaConfigAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
    private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    /// Where the console session comes from. Auto-import keeps working after the
    /// browser session rotates; manual paste is the fallback for when a browser's
    /// cookie store is unreadable.
    enum CookieSource: String {
        case auto
        case manual

        static var current: CookieSource {
            CookieSource(rawValue: UserDefaults.standard.string(forKey: Keys.qwenCookieSource) ?? "") ?? .auto
        }
    }

    /// Resolves the Cookie header to use, preferring an explicit override (the
    /// settings test button), then the configured source.
    ///
    /// - Parameter allowInteraction: only the settings screen passes true. A
    ///   background refresh must never trigger a Keychain approval dialog.
    static func resolveCookie(
        region: QwenRegionConfig,
        override: String? = nil,
        allowInteraction: Bool = false
    ) async -> CookieResolution {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .resolved(header: override.trimmingCharacters(in: .whitespacesAndNewlines), label: S.sourceManualEntry.s)
        }
        let stored = (await Keychain.loadAsync(Keys.qwenCookie, allowInteraction: allowInteraction) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch CookieSource.current {
        case .manual:
            guard !stored.isEmpty else {
                return .missing(S.qwenNeedCookie.s)
            }
            return .resolved(header: stored, label: S.sourceManualPaste.s)
        case .auto:
            if !allowInteraction, let cached = await BrowserSessionCache.shared.header(for: region.id) {
                return .resolved(header: cached.header, label: cached.label)
            }
            let imported = await BrowserCookies.importSessionAsync(
                domains: [region.cookieDomain],
                requiredCookies: Self.requiredCookies,
                allowInteraction: allowInteraction,
                // An approval dialog needs room to be answered.
                timeout: allowInteraction ? 45 : 20
            )
            switch imported {
            case .success(let session):
                await BrowserSessionCache.shared.store(
                    header: session.cookieHeader, label: session.sourceLabel, for: region.id
                )
                Keychain.save(session.cookieHeader, account: Keys.qwenCookieAuto)
                return .resolved(header: session.cookieHeader, label: session.sourceLabel)
            case .failure(let error):
                // Reading the browser's Keychain item can be denied (its ACL only
                // trusts the browser until the user approves us once). Keep serving
                // the last good import rather than going dark.
                let lastGood = (await Keychain.loadAsync(Keys.qwenCookieAuto, allowInteraction: allowInteraction) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !lastGood.isEmpty {
                    return .resolved(header: lastGood, label: S.sourceStoredAuto.s)
                }
                if !stored.isEmpty {
                    return .resolved(header: stored, label: S.sourceManualFallback.s)
                }
                if case .keychainDenied = error {
                    return .missing(S.qwenNeedBrowserAccess.s)
                }
                return .missing(error.errorDescription ?? S.qwenImportFailed.s)
            }
        }
    }

    func fetch() async -> ProviderResult {
        let region = QwenRegionConfig.current()
        let cookie: String
        switch await Self.resolveCookie(
            region: region, override: cookieOverride, allowInteraction: userInitiated
        ) {
        case .resolved(let header, _):
            cookie = header
        case .missing(let message):
            return .needsSetup(message)
        }

        let cacheKey = Self.cacheKey(region: region, cookie: cookie)
        do {
            let usageJSON = try await callWithTokenRetry(
                region: region, api: Self.usageAPI, data: [:], cookie: cookie, cacheKey: cacheKey
            )
            return await buildResult(usageJSON: usageJSON, region: region, cookie: cookie, cacheKey: cacheKey)
        } catch let failure as QwenFailure {
            switch failure {
            // Both mean "the pasted cookie no longer authenticates", so surface
            // them as setup — that is what puts the set-up button in the popover.
            case .loginRequired(let message), .staleToken(let message):
                return .needsSetup(message)
            default:
                return .error(failure.message)
            }
        } catch {
            return .error(S.qwenUnknownError(error.localizedDescription))
        }
    }

    private func buildResult(
        usageJSON: Any,
        region: QwenRegionConfig,
        cookie: String,
        cacheKey: String
    ) async -> ProviderResult {
        guard let usage = JSONWalk.findObject(in: usageJSON, containing: ["per5HourPercentage", "per1WeekPercentage"]) else {
            return .error(S.qwenParseFailedFormat.s)
        }
        let fiveHour = Self.percent(fromRatio: num(usage["per5HourPercentage"]))
        let weekly = Self.percent(fromRatio: num(usage["per1WeekPercentage"]))
        guard fiveHour != nil || weekly != nil else {
            return .error(S.qwenParseFailed.s)
        }

        // Plan name and quota totals are nice-to-have: a failure there must not
        // hide the usage numbers we already have.
        async let subscription = optionalCall(
            region: region, api: Self.subscriptionAPI,
            data: ["commodityCode": region.commodityCode], cookie: cookie, cacheKey: cacheKey
        )
        async let quotaConfig = optionalCall(
            region: region, api: Self.quotaConfigAPI, data: [:], cookie: cookie, cacheKey: cacheKey
        )
        let planCode = await subscription.flatMap(Self.planCode)
        let quota = await quotaConfig.flatMap { Self.quotaTotals(from: $0, planCode: planCode) }

        let planName = Self.resolvePlanName(planCode)
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(UsageWindow(
                name: S.windowFiveHour.s, percent: fiveHour,
                resetsAt: DateParse.parse(usage["per5HourResetTime"]),
                detail: Self.quotaDetail(percent: fiveHour, total: quota?.fiveHour)
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                name: S.windowWeekly.s, percent: weekly,
                resetsAt: DateParse.parse(usage["per1WeekResetTime"]),
                detail: Self.quotaDetail(percent: weekly, total: quota?.weekly)
            ))
        }
        return .ok(planName: planName, windows: windows,
                   limitReached: windows.contains { $0.percent >= 100 },
                   note: await quotaConfig.flatMap(Self.addOnNote))
    }

    // MARK: - Parsing

    /// The gateway reports these windows as a 0..1 ratio, not percentage points.
    static func percent(fromRatio ratio: Double?) -> Double? {
        guard let ratio, ratio.isFinite else { return nil }
        return min(max(ratio, 0), 1) * 100
    }

    static func planCode(from json: Any) -> String? {
        guard let plan = JSONWalk.findObject(in: json, containing: ["specCode", "spec_code", "planName", "plan_name"]) else {
            return nil
        }
        return ["specCode", "spec_code", "planName", "plan_name"]
            .compactMap { plan[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .lowercased()
    }

    /// `quota-config` returns totals keyed by plan code, e.g.
    /// `{"lite": {"five_hour": 1000000, "weekly": 20000000}}`.
    static func quotaTotals(from json: Any, planCode: String?) -> (fiveHour: Double?, weekly: Double?)? {
        guard let planCode,
              let quota = JSONWalk.findFirstValue(forKeys: [planCode], in: json) as? [String: Any] else {
            return nil
        }
        let fiveHour = num(quota["five_hour"] ?? quota["fiveHour"])
        let weekly = num(quota["weekly"] ?? quota["per1Week"])
        guard fiveHour != nil || weekly != nil else { return nil }
        return (fiveHour, weekly)
    }

    /// Extra token packs sit outside the plan quota, so they are not part of any
    /// percentage — but they are what you still have left once the plan is spent.
    static func addOnNote(_ json: Any) -> String? {
        guard let addOn = JSONWalk.findFirstValue(forKeys: ["addon_quota"], in: json) as? [String: Any] else {
            return nil
        }
        let total = addOn.values.compactMap { num($0) }.reduce(0, +)
        guard total > 0 else { return nil }
        return S.qwenAddOnPack(NumberFormat.compact(total))
    }

    static func quotaDetail(percent: Double, total: Double?) -> String? {
        guard let total, total > 0 else { return nil }
        return "\(NumberFormat.compact(total * percent / 100)) / \(NumberFormat.compact(total))"
    }

    /// `subscription` is a best-effort call, so fall back to the generic label
    /// rather than dropping the badge. AppStore remembers the last good value.
    private static func resolvePlanName(_ planCode: String?) -> String? {
        guard let planCode else { return S.qwenPlanPersonal.s }
        return prettyPlan(planCode)
    }

    private static func prettyPlan(_ code: String) -> String {
        switch code.lowercased() {
        case "lite": return "Lite"
        case "standard": return "Standard"
        case "pro": return "Pro"
        case "max": return "Max"
        default: return code
        }
    }

    private static func cacheKey(region: QwenRegionConfig, cookie: String) -> String {
        "\(region.id)#\(cookie.hashValue)"
    }

    // MARK: - Transport

    private func optionalCall(
        region: QwenRegionConfig,
        api: String,
        data: [String: Any],
        cookie: String,
        cacheKey: String
    ) async -> Any? {
        try? await callWithTokenRetry(region: region, api: api, data: data, cookie: cookie, cacheKey: cacheKey)
    }

    /// A cached sec_token can go stale at any time. Rather than surfacing that
    /// as an error the user cannot act on, drop the cache and try once more.
    private func callWithTokenRetry(
        region: QwenRegionConfig,
        api: String,
        data: [String: Any],
        cookie: String,
        cacheKey: String
    ) async throws -> Any {
        let cache = QwenSecTokenCache.shared
        // Verified against the live gateway: these read-only APIs answer 200 with
        // no sec_token at all. So don't pay for the console HTML download up
        // front — only resolve a token if the gateway actually complains.
        let secToken = await cache.token(for: cacheKey)

        do {
            return try await callPersonalAPI(region: region, api: api, data: data, cookie: cookie, secToken: secToken)
        } catch let failure as QwenFailure {
            guard case .staleToken = failure else { throw failure }
            await cache.invalidate(cacheKey)
            let refreshed = await resolveSecToken(region: region, cookie: cookie)
            guard let refreshed else {
                throw QwenFailure.loginRequired(S.qwenConsoleSessionGone.s)
            }
            await cache.store(refreshed, for: cacheKey)
            return try await callPersonalAPI(region: region, api: api, data: data, cookie: cookie, secToken: refreshed)
        }
    }

    private func callPersonalAPI(
        region: QwenRegionConfig,
        api: String,
        data: [String: Any],
        cookie: String,
        secToken: String?
    ) async throws -> Any {
        guard var components = URLComponents(string: region.apiHost + "/data/api.json") else {
            throw QwenFailure.parse(S.internalURLError.s)
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: region.action),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        guard let url = components.url else { throw QwenFailure.parse(S.internalURLError.s) }

        var dataDict = data
        dataDict["cornerstoneParam"] = cornerstoneParam(region: region, cookie: cookie)
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": dataDict]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: paramsData, encoding: .utf8) else {
            throw QwenFailure.parse(S.qwenParamsEncodeFailed.s)
        }

        var pairs: [(String, String)] = [
            ("product", "sfm_bailian"),
            ("action", region.action),
            ("region", region.regionID),
            ("language", "en-US"),
            ("params", paramsString),
        ]
        if let secToken, !secToken.isEmpty {
            pairs.append(("sec_token", secToken))
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.chromeUA, forHTTPHeaderField: "User-Agent")
        request.setValue(region.dashboardOrigin, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL, forHTTPHeaderField: "Referer")
        if let csrf = Self.cookieValue(cookie, name: "login_aliyunid_csrf") ?? Self.cookieValue(cookie, name: "csrf") {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.httpBody = Data(FormEncoding.encode(pairs).utf8)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QwenFailure.network(S.networkError(error.localizedDescription))
        }
        guard response.httpStatus == 200 else {
            if response.httpStatus == 401 || response.httpStatus == 403 {
                // Could be a dead session or just a stale token; retry decides.
                throw QwenFailure.staleToken(S.qwenCookieExpiredOrDenied.s)
            }
            throw QwenFailure.api(S.apiError("Bailian", status: response.httpStatus))
        }
        return try Self.decode(responseData)
    }

    /// NOTE: `cornerstoneParam` must not carry a hardcoded `switchAgent` — the
    /// gateway binds that to one account's workspace, so a captured agent ID
    /// makes every other account fail with `BailianGateway.Workspace.NotAuthorised`.
    private func cornerstoneParam(region: QwenRegionConfig, cookie: String) -> [String: Any] {
        var param: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": region.dashboardURL,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "switchUserType": 3,
            "domain": URL(string: region.dashboardURL)?.host ?? "",
            "consoleSite": region.consoleSite,
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US",
        ]
        if let cna = Self.cookieValue(cookie, name: "cna") {
            param["X-Anonymous-Id"] = cna
        }
        return param
    }

    /// Turns a raw gateway body into JSON, or into the most actionable failure
    /// we can infer from it.
    static func decode(_ data: Data) throws -> Any {
        guard !data.isEmpty else { throw QwenFailure.parse(S.qwenEmptyResponse.s) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            let text = (String(data: data, encoding: .utf8) ?? "").lowercased()
            if text.contains("<html"), text.contains("login") || text.contains("sign in") || text.contains("signin") {
                throw QwenFailure.loginRequired(S.qwenLoginPage.s)
            }
            throw QwenFailure.parse(S.qwenResponseParseFailed.s)
        }
        let expanded = JSONWalk.expandEmbedded(json)
        if let failure = classify(expanded) { throw failure }
        return expanded
    }

    /// The gateway can wrap a real failure in a `200`/`successResponse: true`
    /// envelope, so the innermost failing frame is the authoritative one.
    static func classify(_ json: Any) -> QwenFailure? {
        guard let dict = json as? [String: Any] else { return nil }

        let failingFrames = JSONWalk.objectsFailing(keys: ["successResponse", "Success", "success"], in: dict)
        guard let frame = failingFrames.last else { return nil }

        let code = JSONWalk.findFirstString(forKeys: ["errorCode", "Code", "code", "status", "statusCode"], in: frame)
            ?? JSONWalk.findFirstString(forKeys: ["errorCode", "Code", "code"], in: dict)
        let message = JSONWalk.findFirstString(forKeys: ["errorMsg", "Message", "message", "msg", "statusMessage"], in: frame)
            ?? JSONWalk.findFirstString(forKeys: ["errorMsg", "Message", "message", "msg"], in: dict)

        if let status = JSONWalk.findFirst(forKeys: ["statusCode", "status_code"], in: frame, transform: { num($0) }),
           status == 401 || status == 403 {
            return .loginRequired(S.qwenSessionExpired.s)
        }

        let combined = "\(code ?? "") \(message ?? "")".lowercased()
        let display = (message?.isEmpty == false ? message! : code) ?? S.qwenRequestFailed.s

        // A stale sec_token is reported as a token/expiry error, not a login error.
        if combined.contains("tokenerror") || combined.contains("postonly")
            || combined.contains("request has expired") || combined.contains("refresh page")
            || combined.contains("请求已经过期") {
            return .staleToken(S.qwenTokenStale(display))
        }
        if combined.contains("needlogin") || combined.contains("login") || combined.contains("unauthenticated") {
            return .loginRequired(S.qwenSessionExpiredDetail(display))
        }
        // A workspace permission failure is not a credential failure — telling the
        // user to re-paste a perfectly good cookie just wastes their time.
        if combined.contains("notauthorised") || combined.contains("notauthorized")
            || combined.contains("forbidden") || combined.contains("permission") {
            return .forbidden(S.qwenForbidden(display))
        }
        return .api(S.qwenGatewayError(display))
    }

    // MARK: - sec_token

    private func resolveSecToken(region: QwenRegionConfig, cookie: String) async -> String? {
        if let html = await fetchText(region.dashboardURL, cookie: cookie, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
           let token = Self.extractSecToken(html: html) {
            return token
        }
        if let cookieToken = Self.cookieValue(cookie, name: "sec_token") {
            return cookieToken
        }
        if let text = await fetchText(region.dashboardOrigin + "/tool/user/info.json", cookie: cookie, accept: "application/json, text/plain, */*"),
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            let expanded = JSONWalk.expandEmbedded(json)
            return JSONWalk.findFirstString(forKeys: ["secToken", "sec_token", "csrfToken"], in: expanded)
        }
        return nil
    }

    private func fetchText(_ urlString: String, cookie: String, accept: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              response.httpStatus == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func extractSecToken(html: String) -> String? {
        // A login redirect renders a page with no token; bail out rather than
        // matching some unrelated `token:` string in the login bundle.
        let lowered = html.lowercased()
        if lowered.contains("passport") && lowered.contains("<form") && !lowered.contains("sectoken") {
            return nil
        }
        let patterns = [
            #"\"secToken\"\s*:\s*\"([^\"]+)\""#,
            #"\"sec_token\"\s*:\s*\"([^\"]+)\""#,
            #"secToken[\"']?\s*[:=]\s*[\"']([^\"']+)[\"']"#,
            #"sec_token[\"']?\s*[:=]\s*[\"']([^\"']+)[\"']"#,
            #"csrfToken[\"']?\s*[:=]\s*[\"']([^\"']+)[\"']"#,
        ]
        let range = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[groupRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func cookieValue(_ cookie: String, name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix(name + "=") {
                let value = String(piece.dropFirst(name.count + 1))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
