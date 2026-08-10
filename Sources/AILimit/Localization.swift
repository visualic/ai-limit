import Foundation

enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"

    /// Resolved language: an explicit choice in Settings, otherwise whatever the
    /// system prefers.
    static var current: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: Keys.language),
           let explicit = AppLanguage(rawValue: raw) {
            return explicit
        }
        return systemDefault
    }

    static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? .korean : .english
    }
}

/// A string that exists in both languages.
///
/// Storing both translations in one value makes a missing translation
/// unrepresentable: you cannot add UI copy without also writing the other
/// language, so there is nothing to audit for later.
struct Localized {
    let ko: String
    let en: String

    init(_ ko: String, _ en: String) {
        self.ko = ko
        self.en = en
    }

    /// The text for the active language.
    var s: String { AppLanguage.current == .korean ? ko : en }
}

/// Every user-facing string in the app.
enum S {

    // MARK: - Popover

    static let appTitle = Localized("AI 한도", "AI Limits")
    static let statusItemTooltip = Localized("AI 구독 한도", "AI subscription limits")
    static let loading = Localized("불러오는 중…", "Loading…")
    static let autoRefreshFooter = Localized("설정한 주기마다 자동으로 갱신돼요",
                                             "Refreshes automatically on your chosen interval")
    static let refreshNow = Localized("지금 갱신", "Refresh now")
    static let settings = Localized("설정", "Settings")
    static let quit = Localized("종료", "Quit")
    static let limitReached = Localized("한도 도달", "Limit reached")
    static let noUsageData = Localized("사용량 정보가 없어요", "No usage data")
    static let setUpCookie = Localized("쿠키 설정하기", "Set up cookie")
    static let openLoginPage = Localized("로그인 페이지 열기", "Open login page")
    static func checkFailed(_ provider: String) -> String {
        AppLanguage.current == .korean ? "\(provider): 확인 실패" : "\(provider): check failed"
    }

    // MARK: - Usage windows

    static let windowFiveHour = Localized("5시간", "5-hour")
    static let windowWeekly = Localized("주간", "Weekly")
    static let windowPlan = Localized("플랜", "Plan")
    static let windowOnDemand = Localized("추가 사용량", "On-demand")
    static let windowPersonalCap = Localized("개인 한도", "Personal cap")
    static let windowGeneric = Localized("사용량", "Usage")
    static func weeklyScoped(_ model: String) -> String {
        AppLanguage.current == .korean ? "주간 · \(model)" : "Weekly · \(model)"
    }
    static let weeklyScopedFallback = Localized("주간 · 모델", "Weekly · model")
    static func hourWindow(_ hours: Int) -> String {
        AppLanguage.current == .korean ? "\(hours)시간" : "\(hours)-hour"
    }
    static func dayWindow(_ days: Int) -> String {
        AppLanguage.current == .korean ? "\(days)일" : "\(days)-day"
    }

    // MARK: - Reset countdown

    static let resetsSoon = Localized("곧 리셋", "resets soon")
    static func resetsOn(_ date: String) -> String {
        AppLanguage.current == .korean ? "\(date) 리셋" : "resets \(date)"
    }
    static func resetsIn(days: Int, hours: Int, minutes: Int) -> String {
        if AppLanguage.current == .korean {
            if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간 후 리셋" : "\(days)일 후 리셋" }
            if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분 후 리셋" : "\(hours)시간 후 리셋" }
            return "\(max(1, minutes))분 후 리셋"
        }
        if days > 0 { return hours > 0 ? "resets in \(days)d \(hours)h" : "resets in \(days)d" }
        if hours > 0 { return minutes > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(hours)h" }
        return "resets in \(max(1, minutes))m"
    }

    // MARK: - Shared errors

    static func networkError(_ detail: String) -> String {
        AppLanguage.current == .korean ? "네트워크 오류: \(detail)" : "Network error: \(detail)"
    }
    static func apiError(_ service: String, status: Int) -> String {
        AppLanguage.current == .korean
            ? "\(service) API 오류 (HTTP \(status))"
            : "\(service) API error (HTTP \(status))"
    }
    static func parseFailed(_ service: String) -> String {
        AppLanguage.current == .korean
            ? "\(service) 응답을 파싱하지 못했어요."
            : "Could not parse the \(service) response."
    }
    static let internalURLError = Localized("내부 오류: URL 생성 실패", "Internal error: could not build URL")

    // MARK: - Claude

    static let claudeNoCredentials = Localized(
        "Claude Code 자격증명을 찾지 못했어요. 터미널에서 `claude`를 한 번 실행해 로그인해 주세요.",
        "No Claude Code credentials found. Run `claude` once in a terminal to sign in.")
    static let claudeExpired = Localized(
        "Claude Code 로그인이 만료됐어요. 터미널에서 `claude`를 한 번 실행하면 갱신돼요.",
        "Your Claude Code session expired. Run `claude` once in a terminal to renew it.")
    static let claudeAuthExpired = Localized(
        "Claude 인증이 만료됐어요. 터미널에서 `claude`를 한 번 실행하면 갱신돼요.",
        "Claude authentication expired. Run `claude` once in a terminal to renew it.")
    static let claudeNoUsage = Localized("Claude 사용량 데이터를 찾지 못했어요.",
                                         "Could not find Claude usage data.")
    static func claudeRateLimited(_ when: String) -> String {
        AppLanguage.current == .korean
            ? "Anthropic이 요청 빈도를 제한했어요. \(when) 자동으로 다시 시도해요."
            : "Anthropic is rate limiting requests. Retrying automatically \(when)."
    }
    static let rateLimitSoon = Localized("잠시 후", "shortly")
    static func extraUsageCredits(_ used: String, _ limit: String) -> String {
        AppLanguage.current == .korean
            ? "추가 사용량 \(used) / \(limit) 크레딧"
            : "On-demand \(used) / \(limit) credits"
    }
    static func extraUsagePercent(_ percent: Int) -> String {
        AppLanguage.current == .korean ? "추가 사용량 \(percent)%" : "On-demand \(percent)%"
    }
    static let extraUsageOn = Localized("추가 사용량 사용 중", "On-demand usage enabled")
    static func creditsSpent(_ amount: String) -> String {
        AppLanguage.current == .korean ? "크레딧 사용 \(amount)" : "\(amount) of credits used"
    }

    // MARK: - OpenAI

    static let openAINoCredentials = Localized(
        "~/.codex/auth.json 에서 토큰을 찾지 못했어요. 터미널에서 Codex CLI로 한 번 로그인해 주세요.",
        "No token in ~/.codex/auth.json. Sign in once with the Codex CLI.")
    static let openAIRefreshFailed = Localized(
        "OpenAI 토큰 갱신에 실패했어요. 터미널에서 `codex`를 한 번 실행해 로그인해 주세요.",
        "Could not refresh the OpenAI token. Run `codex` once in a terminal to sign in.")
    static let openAIAuthExpired = Localized(
        "OpenAI 인증이 만료됐어요. 터미널에서 `codex`를 한 번 실행해 로그인해 주세요.",
        "OpenAI authentication expired. Run `codex` once in a terminal to sign in.")
    static let openAINoUsage = Localized("OpenAI 사용량 데이터를 찾지 못했어요.",
                                         "Could not find OpenAI usage data.")
    static let creditsUnlimited = Localized("크레딧 무제한", "Unlimited credits")
    static func creditsLeft(_ amount: String) -> String {
        AppLanguage.current == .korean ? "크레딧 \(amount) 남음" : "\(amount) credits left"
    }
    static let creditsAvailable = Localized("크레딧 있음", "Credits available")

    // MARK: - Cursor

    static let cursorSessionExpiredApp = Localized(
        "Cursor 세션이 만료됐어요. Cursor 앱에서 다시 로그인해 주세요.",
        "Your Cursor session expired. Sign in again in the Cursor app.")
    static let cursorSessionExpiredWeb = Localized(
        "Cursor 세션이 만료됐어요. 브라우저에서 cursor.com에 다시 로그인해 주세요.",
        "Your Cursor session expired. Sign in to cursor.com again in your browser.")
    static let cursorNotSignedInApp = Localized(
        "Cursor 앱에 로그인되어 있지 않아요. Cursor를 열어 로그인해 주세요.",
        "Not signed in to the Cursor app. Open Cursor and sign in.")
    static let cursorNotSignedInWeb = Localized(
        "브라우저에서 cursor.com에 로그인되어 있지 않아요.",
        "Not signed in to cursor.com in your browser.")
    static let cursorNoUsage = Localized("Cursor 사용량 데이터를 찾지 못했어요.",
                                         "Could not find Cursor usage data.")
    static let cursorCookieFailed = Localized("Cursor 쿠키를 가져오지 못했어요.",
                                              "Could not import Cursor cookies.")
    static let cursorNoIncludedUsage = Localized("요금제에 포함된 사용량이 없어요",
                                                 "This plan includes no usage allowance")
    static func onDemandUncapped(_ amount: String) -> String {
        AppLanguage.current == .korean ? "추가 사용량 \(amount) (한도 없음)"
                                       : "On-demand \(amount) (no cap)"
    }

    // MARK: - Qwen

    static let qwenNeedCookie = Localized(
        "Bailian 콘솔 쿠키가 필요해요. 설정에서 Cookie 헤더를 붙여넣어 주세요.",
        "A Bailian console cookie is required. Paste the Cookie header in Settings.")
    static let qwenNeedBrowserAccess = Localized(
        "브라우저 쿠키 접근 권한이 필요해요. 설정에서 \"지금 가져오기 테스트\"를 한 번 눌러 허용해 주세요.",
        "Browser cookie access is required. Press \"Import now\" in Settings once to allow it.")
    static let qwenImportFailed = Localized("브라우저에서 쿠키를 가져오지 못했어요.",
                                            "Could not import cookies from the browser.")
    static let qwenParseFailedFormat = Localized(
        "사용량 데이터를 파싱하지 못했어요. (응답 형식이 바뀌었을 수 있어요)",
        "Could not parse the usage data — the response format may have changed.")
    static let qwenParseFailed = Localized("사용량 데이터를 파싱하지 못했어요.",
                                           "Could not parse the usage data.")
    static let qwenEmptyResponse = Localized("빈 응답을 받았어요.", "Received an empty response.")
    static let qwenResponseParseFailed = Localized("응답을 파싱하지 못했어요.",
                                                   "Could not parse the response.")
    static let qwenLoginPage = Localized(
        "로그인 페이지가 돌아왔어요. 콘솔에 다시 로그인한 뒤 쿠키를 다시 붙여넣어 주세요.",
        "Got a login page back. Sign in to the console again, then re-import the cookie.")
    static let qwenSessionExpired = Localized(
        "세션이 만료됐어요. 콘솔에 다시 로그인한 뒤 쿠키를 다시 붙여넣어 주세요.",
        "Your session expired. Sign in to the console again, then re-import the cookie.")
    static let qwenCookieExpiredOrDenied = Localized(
        "쿠키가 만료됐거나 권한이 없어요. 콘솔에 다시 로그인한 뒤 쿠키를 다시 붙여넣어 주세요.",
        "The cookie expired or lacks permission. Sign in again, then re-import the cookie.")
    static let qwenConsoleSessionGone = Localized(
        "콘솔 세션이 만료된 것 같아요. 콘솔에 다시 로그인한 뒤 쿠키를 다시 붙여넣어 주세요.",
        "The console session looks gone. Sign in again, then re-import the cookie.")
    static func qwenTokenStale(_ detail: String) -> String {
        AppLanguage.current == .korean
            ? "보안 토큰이 만료돼 재시도했어요. 계속 실패하면 쿠키를 다시 붙여넣어 주세요. (\(detail))"
            : "The security token expired and was retried. If this persists, re-import the cookie. (\(detail))"
    }
    static func qwenSessionExpiredDetail(_ detail: String) -> String {
        AppLanguage.current == .korean
            ? "세션이 만료됐어요. 콘솔에 다시 로그인한 뒤 쿠키를 다시 붙여넣어 주세요. (\(detail))"
            : "Your session expired. Sign in again, then re-import the cookie. (\(detail))"
    }
    static func qwenForbidden(_ detail: String) -> String {
        AppLanguage.current == .korean
            ? "이 계정에 Token Plan 조회 권한이 없어요. 콘솔에서 워크스페이스/권한을 확인해 주세요. (\(detail))"
            : "This account cannot read the Token Plan. Check workspace permissions in the console. (\(detail))"
    }
    static func qwenGatewayError(_ detail: String) -> String {
        AppLanguage.current == .korean ? "Bailian 오류: \(detail)" : "Bailian error: \(detail)"
    }
    static let qwenRequestFailed = Localized("요청이 실패했어요", "the request failed")
    static let qwenParamsEncodeFailed = Localized("내부 오류: params 인코딩 실패",
                                                  "Internal error: could not encode params")
    static let qwenUnknownError = Localized("알 수 없는 오류", "Unknown error")
    static func qwenUnknownError(_ detail: String) -> String {
        AppLanguage.current == .korean ? "알 수 없는 오류: \(detail)" : "Unknown error: \(detail)"
    }
    static func qwenAddOnPack(_ amount: String) -> String {
        AppLanguage.current == .korean ? "추가 팩 \(amount)" : "Add-on pack \(amount)"
    }
    static let qwenPlanPersonal = Localized("Personal", "Personal")

    // MARK: - Browser cookie import

    static let browserNotFound = Localized("Chrome 계열 브라우저를 찾지 못했어요.",
                                           "No Chromium-based browser found.")
    static func keychainDenied(_ browser: String) -> String {
        AppLanguage.current == .korean
            ? "\(browser)의 Keychain 암호화 키를 읽지 못했어요. 접근 허용을 눌러 주세요."
            : "Could not read \(browser)'s Keychain encryption key. Choose Allow when prompted."
    }
    static func noMatchingCookies(_ browser: String) -> String {
        AppLanguage.current == .korean
            ? "\(browser)에 로그인된 세션이 없어요. 브라우저에서 먼저 로그인해 주세요."
            : "No signed-in session in \(browser). Sign in there first."
    }
    static func cookieReadFailed(_ detail: String) -> String {
        AppLanguage.current == .korean ? "쿠키를 읽지 못했어요: \(detail)"
                                       : "Could not read cookies: \(detail)"
    }
    static let databaseOpenFailed = Localized("데이터베이스를 열지 못했어요",
                                              "could not open the database")
    static let browserGeneric = Localized("브라우저", "the browser")
    static let sourceManualEntry = Localized("직접 입력", "Manual entry")
    static let sourceManualPaste = Localized("직접 붙여넣기", "Pasted manually")
    static let sourceManualFallback = Localized("직접 붙여넣기 (자동 가져오기 실패)",
                                                "Pasted manually (auto-import failed)")
    static let sourceStoredAuto = Localized("저장된 자동 쿠키", "Saved imported cookie")
    static let sourceCursorApp = Localized("Cursor 앱", "Cursor app")

    // MARK: - Settings

    static let settingsWindowTitle = Localized("AILimit 설정", "AILimit Settings")
    static let sectionGeneral = Localized("일반", "General")
    static let refreshInterval = Localized("자동 갱신 주기", "Refresh interval")
    static let showPercent = Localized("메뉴바 아이콘에 퍼센트 표시", "Show percentage in the menu bar")
    static let menuBarProvider = Localized("메뉴바에 표시할 서비스", "Service shown in the menu bar")
    static let menuBarProviderHelp = Localized(
        "막대는 설정된 서비스를 모두 보여주고, 숫자는 여기서 고른 하나만 보여줍니다. 한 서비스가 며칠씩 100%로 차 있어도 나머지를 계속 확인할 수 있어요.",
        "The bars show every configured service; the number shows only the one you pick here. That way a service stuck at 100% for days cannot hide the others.")
    static let highestValue = Localized("가장 높은 값", "Highest value")
    static let language = Localized("언어", "Language")
    static let languageSystem = Localized("시스템 설정", "System")
    static let languageKorean = Localized("한국어", "한국어")
    static let languageEnglish = Localized("English", "English")
    static func minutes(_ count: Int) -> String {
        AppLanguage.current == .korean ? "\(count)분" : "\(count) min"
    }

    static let sectionCursor = Localized("Cursor", "Cursor")
    static let cursorHelp = Localized(
        "Cursor 앱의 로그인 세션을 그대로 읽습니다. 앱에 로그인되어 있으면 별도 설정이 필요 없고, 앱이 없으면 브라우저 쿠키로 대체합니다.",
        "Reads the session the Cursor app already holds. Nothing to configure when you are signed in there; falls back to browser cookies if the app is absent.")
    static let importNow = Localized("지금 가져오기 테스트", "Import now")
    static let openCursorDashboard = Localized("Cursor 대시보드 열기 (브라우저에서 로그인)",
                                               "Open the Cursor dashboard (sign in there)")

    static let sectionQwen = Localized("Qwen · Alibaba Token Plan", "Qwen · Alibaba Token Plan")
    static let region = Localized("리전", "Region")
    static let regionIntl = Localized("국제 (Singapore)", "International (Singapore)")
    static let regionChina = Localized("중국 (Aliyun)", "China (Aliyun)")
    static let cookieSource = Localized("쿠키 가져오기", "Cookie source")
    static let cookieSourceAuto = Localized("브라우저에서 자동", "Automatic, from the browser")
    static let cookieSourceManual = Localized("직접 붙여넣기", "Paste manually")
    static let qwenAutoHelp = Localized(
        "Chrome·Brave·Edge·Arc 등에서 Alibaba 콘솔 로그인 세션을 자동으로 읽어옵니다. 브라우저에서 콘솔에 로그인만 되어 있으면 별도 설정이 필요 없고, 세션이 갱신되면 자동으로 따라갑니다. (최초 1회 Keychain 접근 허용이 필요할 수 있어요)",
        "Reads your Alibaba console session from Chrome, Brave, Edge, Arc and friends. Nothing to configure as long as you are signed in there, and it follows the session as it rotates. (macOS may ask once for Keychain access.)")
    static let qwenManualHelp = Localized(
        "① 아래 링크로 콘솔 페이지를 열어 로그인한 뒤, ② F12(개발자도구) → Network 탭에서 Cmd+R로 새로고침해 요청이 생기게 하고, ③ 목록의 아무 요청이나 우클릭 → Copy → Copy as cURL 을 눌러 복사한 걸 아래 칸에 그대로 붙여넣으세요. Cookie는 앱이 자동으로 찾아줍니다.",
        "1. Open the console below and sign in. 2. Press F12, open the Network tab and reload with Cmd+R so requests appear. 3. Right-click any request → Copy → Copy as cURL, and paste the whole thing below. The Cookie header is extracted for you.")
    static let openTokenPlanBrowser = Localized("Token Plan 페이지 열기 (브라우저에서 로그인)",
                                                "Open the Token Plan page (sign in there)")
    static let openTokenPlanCopy = Localized("Token Plan 페이지 열기 (여기서 로그인 후 쿠키 복사)",
                                             "Open the Token Plan page (sign in, then copy the cookie)")
    static let pasteHint = Localized("cURL 명령어 전체를 붙여넣거나, Cookie 헤더 값만 붙여넣거나 둘 다 됩니다.",
                                     "Paste the whole cURL command or just the Cookie header — either works.")
    static let save = Localized("저장", "Save")
    static let testConnection = Localized("연결 테스트", "Test connection")
    static let delete = Localized("삭제", "Delete")
    static let cookieNotFound = Localized(
        "실패: 붙여넣은 내용에서 Cookie를 찾지 못했어요. 요청 우클릭 → Copy → Copy as cURL 로 복사했는지 확인해 주세요.",
        "Failed: no Cookie found in what you pasted. Make sure you used Copy → Copy as cURL.")
    static func importSucceeded(_ source: String, _ count: Int) -> String {
        AppLanguage.current == .korean
            ? "성공! \(source) 에서 쿠키 \(count)개를 읽었어요."
            : "Success — read \(count) cookies from \(source)."
    }
    static func importFailed(_ detail: String) -> String {
        AppLanguage.current == .korean ? "실패: \(detail)" : "Failed: \(detail)"
    }
    static func testSucceeded(_ plan: String, _ summary: String) -> String {
        let head = AppLanguage.current == .korean ? "성공! 플랜: \(plan)" : "Success — plan: \(plan)"
        return summary.isEmpty ? head : head + ", " + summary
    }
    static let unknownError = Localized("알 수 없는 오류", "Unknown error")

    /// Success/failure prefixes are matched to colour the message, so they need
    /// one place rather than a literal at each comparison site.
    static var successPrefix: String { AppLanguage.current == .korean ? "성공" : "Success" }
}
