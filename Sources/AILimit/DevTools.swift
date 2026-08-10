#if DEBUG
import AppKit
import SwiftUI

// MARK: - Popover layout preview

/// `--preview` renders PopoverView inside a real NSPopover with representative
/// mock data and screenshots it, so layout regressions (clipping, truncation)
/// can be caught without driving the status item by hand.
@MainActor
enum UIPreview {
    static let mocks: [ProviderSnapshot] = [
        ProviderSnapshot(
            id: "claude", displayName: "Claude", planName: "Max 5x",
            windows: [
                UsageWindow(name: "5시간", percent: 100, resetsAt: Date().addingTimeInterval(3_600)),
                UsageWindow(name: "주간", percent: 46, resetsAt: Date().addingTimeInterval(86_400 * 3)),
                UsageWindow(name: "주간 · Claude Opus 4.5", percent: 22, resetsAt: Date().addingTimeInterval(86_400 * 3)),
            ],
            fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: true,
            note: "추가 사용량 12 / 50 크레딧"
        ),
        ProviderSnapshot(
            id: "openai", displayName: "OpenAI Codex", planName: "Pro Lite",
            windows: [
                UsageWindow(name: "5시간", percent: 7, resetsAt: Date().addingTimeInterval(1_200)),
                UsageWindow(name: "주간", percent: 100, resetsAt: Date().addingTimeInterval(86_400 * 5)),
                UsageWindow(name: "gpt-5-codex-high", percent: 63, resetsAt: nil),
            ],
            fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: true,
            note: "크레딧 5 남음"
        ),
        ProviderSnapshot(
            id: "cursor", displayName: "Cursor", planName: "Free",
            windows: [], fetchedAt: Date(), errorMessage: nil, needsSetup: false,
            limitReached: false, note: "요금제에 포함된 사용량이 없어요"
        ),
        ProviderSnapshot(
            id: "qwen", displayName: "Qwen Token Plan", planName: "Lite",
            windows: [
                UsageWindow(name: "5시간", percent: 34, resetsAt: Date().addingTimeInterval(9_000), detail: "340K / 1M"),
                UsageWindow(name: "주간", percent: 71, resetsAt: Date().addingTimeInterval(86_400 * 2), detail: "14.2M / 20M"),
            ],
            fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: false,
            note: "추가 팩 20,000"
        ),
    ]

    /// Same layout, but exercising the error/setup branch of every card.
    static let errorMocks: [ProviderSnapshot] = [
        ProviderSnapshot(
            id: "claude", displayName: "Claude", planName: nil, windows: [], fetchedAt: Date(),
            errorMessage: "Claude 인증이 만료됐어요. 터미널에서 `claude`를 한 번 실행하면 갱신돼요.",
            needsSetup: false, limitReached: false
        ),
        ProviderSnapshot(
            id: "qwen", displayName: "Qwen Token Plan", planName: nil, windows: [], fetchedAt: Date(),
            errorMessage: "Bailian 콘솔 쿠키가 필요해요. 설정에서 Cookie 헤더를 붙여넣어 주세요.",
            needsSetup: true, limitReached: false
        ),
    ]

    static func run(useErrorMocks: Bool, output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let store = AppStore()
        let anchor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        anchor.backgroundColor = .clear
        anchor.setFrameOrigin(NSPoint(x: 420, y: 640))
        anchor.makeKeyAndOrderFront(nil)

        let hosting = NSHostingController(rootView: PopoverView(
            store: store, onOpenSettings: {}, onHover: { _ in }
        ))
        hosting.sizingOptions = [.intrinsicContentSize]
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .applicationDefined

        app.activate(ignoringOtherApps: true)

        // Let AppStore's startup refresh land first so it cannot overwrite the mocks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            store.snapshots = useErrorMocks ? errorMocks : mocks
            store.lastUpdated = Date()
            guard let view = anchor.contentView else { exit(1) }

            // Mirrors AppDelegate.syncPopoverSize().
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = hosting.view.fittingSize
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let window = popover.contentViewController?.view.window
                print("content fittingSize=\(hosting.view.fittingSize) popover.contentSize=\(popover.contentSize)")
                print("window frame=\(window?.frame.debugDescription ?? "nil")")
                let task = Process()
                task.launchPath = "/usr/sbin/screencapture"
                task.arguments = ["-x", "-o", "-l\(CGWindowID(window?.windowNumber ?? 0))", output]
                try? task.run()
                task.waitUntilExit()
                print("captured -> \(output)")
                exit(0)
            }
        }
        app.run()
    }
}

/// `--preview-app` boots the real AppDelegate (status item, tracking area,
/// popover) and shows the popover through the shipping code path.
@MainActor
enum AppPreview {
    private static var delegate: AppDelegate?

    static func run(output: String, settings: Bool = false, live: Bool = false) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + (live ? 15.0 : 2.0)) {
            if settings {
                delegate.openSettings()
            } else if live {
                delegate.debugShowPopoverLive()
            } else {
                delegate.debugShowPopover(with: UIPreview.mocks)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let popover = delegate.debugPopover
                let window = settings
                    ? NSApp.windows.first { $0.title == S.settingsWindowTitle.s }
                    : popover.contentViewController?.view.window
                print("popover.contentSize=\(popover.contentSize)")
                print("window frame=\(window?.frame.debugDescription ?? "nil")")
                let task = Process()
                task.launchPath = "/usr/sbin/screencapture"
                task.arguments = ["-x", "-o", "-l\(CGWindowID(window?.windowNumber ?? 0))", output]
                try? task.run()
                task.waitUntilExit()
                print("captured -> \(output)")
                exit(0)
            }
        }
        app.run()
    }
}

/// `--screenshot` renders the real views into PNGs for the README.
///
/// Rendered offscreen through `cacheDisplay` rather than captured from the
/// screen: window capture needs an awake, unlocked display and Screen Recording
/// permission, none of which hold in a scripted run. This also keeps the images
/// reproducible — the same command always produces the same picture.
@MainActor
enum Screenshot {
    /// Fabricated data. These images ship in a public repository, so they must
    /// never contain the developer's real subscription usage.
    ///
    /// Built as a computed property, not a constant: window names and notes come
    /// from the same localized strings the providers use, so the sample has to be
    /// rebuilt after the language changes or the screenshots would show Korean
    /// labels under an English UI.
    static var sample: [ProviderSnapshot] {
        [
            ProviderSnapshot(
                id: "claude", displayName: "Claude", planName: "Max",
                windows: [
                    UsageWindow(name: S.windowFiveHour.s, percent: 42,
                                resetsAt: Date().addingTimeInterval(3_600 * 3 + 900)),
                    UsageWindow(name: S.windowWeekly.s, percent: 18,
                                resetsAt: Date().addingTimeInterval(86_400 * 4)),
                    UsageWindow(name: S.weeklyScoped("Claude Opus 4.5"), percent: 7,
                                resetsAt: Date().addingTimeInterval(86_400 * 4)),
                ],
                fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: false
            ),
            ProviderSnapshot(
                id: "openai", displayName: "OpenAI Codex", planName: "Plus",
                windows: [
                    UsageWindow(name: S.windowFiveHour.s, percent: 63,
                                resetsAt: Date().addingTimeInterval(2_400)),
                    UsageWindow(name: S.windowWeekly.s, percent: 88,
                                resetsAt: Date().addingTimeInterval(86_400 * 2 + 3_600 * 5)),
                ],
                fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: false,
                note: S.creditsLeft("12")
            ),
            ProviderSnapshot(
                id: "cursor", displayName: "Cursor", planName: "Pro",
                windows: [
                    UsageWindow(name: S.windowPlan.s, percent: 55,
                                resetsAt: Date().addingTimeInterval(86_400 * 11), detail: "$11 / $20"),
                ],
                fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: false
            ),
            ProviderSnapshot(
                id: "qwen", displayName: "Qwen Token Plan", planName: "Standard",
                windows: [
                    UsageWindow(name: S.windowFiveHour.s, percent: 24,
                                resetsAt: Date().addingTimeInterval(9_000), detail: "720 / 3,000"),
                    UsageWindow(name: S.windowWeekly.s, percent: 100,
                                resetsAt: Date().addingTimeInterval(86_400 + 3_600 * 8),
                                detail: "10,000 / 10,000"),
                ],
                fetchedAt: Date(), errorMessage: nil, needsSetup: false, limitReached: true
            ),
        ]
    }

    static func run(directory: String) {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.string(forKey: Keys.language)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: Keys.language) }
            else { UserDefaults.standard.removeObject(forKey: Keys.language) }
        }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            let suffix = language == .korean ? "" : "-en"
            for (name, dark) in [("popover-light", false), ("popover-dark", true)] {
                guard let data = renderPopover(dark: dark) else {
                    print("failed: \(name)\(suffix)"); continue
                }
                let path = "\(directory)/\(name)\(suffix).png"
                try? data.write(to: URL(fileURLWithPath: path))
                print("  \(path)")
            }
        }
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: Keys.language)
        if let data = renderMenuBar() {
            let path = "\(directory)/menubar.png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("  \(path)")
        }
    }

    private static func renderPopover(dark: Bool) -> Data? {
        let store = AppStore()
        store.snapshots = sample
        store.lastUpdated = Date()

        let hosting = NSHostingView(rootView: PopoverView(
            store: store, onOpenSettings: {}, onHover: { _ in }
        ))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // A hosting view only lays out inside a window, and the popover's
        // material background needs one to resolve against.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 800)),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Without this the window paints an opaque white backing that
        // `cacheDisplay` captures, so dark-mode label colours land on white and
        // the header and footer vanish.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1)
                                               : NSColor(white: 1.0, alpha: 1)).cgColor
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        return bitmap(of: hosting, background: dark ? NSColor(white: 0.13, alpha: 1)
                                                    : NSColor(white: 0.96, alpha: 1))
    }

    private static func renderMenuBar() -> Data? {
        let entries = sample.map {
            MeterIcon.Entry(percent: $0.worstPercent, color: MeterIcon.color(for: $0.worstPercent))
        }
        let icon = MeterIcon.image(entries: entries)
        let width: CGFloat = 132, height: CGFloat = 24
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                     xRadius: 6, yRadius: 6).fill()
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            icon.draw(at: NSPoint(x: 14, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            NSAttributedString(string: " 42%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white,
            ]).draw(at: NSPoint(x: 14 + icon.size.width, y: 4))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func bitmap(of view: NSView, background: NSColor) -> Data? {
        let inset: CGFloat = 16
        let padded = NSRect(x: 0, y: 0,
                            width: view.bounds.width + inset * 2,
                            height: view.bounds.height + inset * 2)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Compose onto a padded backdrop so the card edges are visible on
        // GitHub's own light and dark page backgrounds.
        let canvas = NSImage(size: padded.size)
        canvas.lockFocus()
        background.setFill()
        NSBezierPath(roundedRect: padded, xRadius: 12, yRadius: 12).fill()
        rep.draw(in: NSRect(x: inset, y: inset, width: view.bounds.width, height: view.bounds.height))
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let out = NSBitmapImageRep(data: tiff) else { return nil }
        return out.representation(using: .png, properties: [:])
    }
}

/// `--icon-preview` renders the shipping MeterIcon at every provider count on
/// light and dark menu-bar backgrounds, so the 2-provider case can be judged
/// before shipping rather than after.
@MainActor
enum IconPreview {
    static func run(output: String) {
        let sets: [(String, [MeterIcon.Entry])] = [
            ("1개 (Claude만)", [.init(percent: 42, color: .systemGreen)]),
            ("2개 (Claude + Cursor)", [.init(percent: 42, color: .systemGreen),
                                       .init(percent: 78, color: .systemOrange)]),
            ("3개", [.init(percent: 42, color: .systemGreen),
                     .init(percent: 100, color: .systemRed),
                     .init(percent: 78, color: .systemOrange)]),
            ("4개 (전체)", [.init(percent: 42, color: .systemGreen),
                          .init(percent: 100, color: .systemRed),
                          .init(percent: 78, color: .systemOrange),
                          .init(percent: 100, color: .systemRed)]),
            ("4개 중 1개 확인 실패", [.init(percent: 42, color: .systemGreen),
                                .unknown(),
                                .init(percent: 3, color: .systemGreen),
                                .init(percent: 100, color: .systemRed)]),
            ("0개 (미설정)", []),
        ]
        let scale: CGFloat = 4, rowH: CGFloat = 30, W: CGFloat = 300
        let H = rowH * CGFloat(sets.count) + 10
        let image = NSImage(size: NSSize(width: W * scale, height: H * scale))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        for (index, entry) in sets.enumerated() {
            let y = H - rowH * CGFloat(index + 1)
            for (col, dark) in [(CGFloat(10), false), (CGFloat(120), true)] {
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: col, y: y + 3, width: 96, height: 22),
                             xRadius: 5, yRadius: 5).fill()
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                appearance?.performAsCurrentDrawingAppearance {
                    let icon = MeterIcon.image(entries: entry.1)
                    icon.draw(at: NSPoint(x: col + 10, y: y + 5), from: .zero,
                              operation: .sourceOver, fraction: 1)
                    let pct = entry.1.first?.percent
                    let text = pct.map { String(format: " %.0f%%", $0) } ?? ""
                    NSAttributedString(string: text, attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: dark ? NSColor.white : NSColor.black,
                    ]).draw(at: NSPoint(x: col + 12 + icon.size.width, y: y + 7))
                }
            }
            NSAttributedString(string: entry.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
            ]).draw(at: NSPoint(x: 226, y: y + 8))
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print("captured -> \(output)")
    }
}

// MARK: - Qwen parsing self-test

/// `--selftest` exercises the Qwen response parsing and error classification
/// against captured payload shapes. The live gateway needs a browser cookie we
/// cannot assume is present, so this is what keeps the parser honest.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        if passed {
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    private static func json(_ text: String) -> Any {
        JSONWalk.expandEmbedded(try! JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    static func run() -> Int {
        // Assertions below are written against the Korean copy, so pin the
        // language: otherwise the suite passes or fails depending on the
        // machine's system locale.
        let previousLanguage = UserDefaults.standard.string(forKey: Keys.language)
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: Keys.language)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: Keys.language)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.language)
            }
        }

        print("== Qwen ratio → percent")
        check("0.46 → 46", QwenProvider.percent(fromRatio: 0.46) == 46)
        check("1.0 → 100", QwenProvider.percent(fromRatio: 1.0) == 100)
        check("clamps 1.5 → 100", QwenProvider.percent(fromRatio: 1.5) == 100)
        check("clamps -0.1 → 0", QwenProvider.percent(fromRatio: -0.1) == 0)
        check("nil → nil", QwenProvider.percent(fromRatio: nil) == nil)
        check("NaN → nil", QwenProvider.percent(fromRatio: .nan) == nil)

        print("== Qwen error classification")
        check("healthy payload is not an error", QwenProvider.classify(json("""
        {"code":"200","successResponse":true,"data":{"success":true,"per5HourPercentage":0.3}}
        """)) == nil)

        // The gateway wraps a real failure in an outer 200 envelope; the inner
        // frame carries the actionable code.
        if case .staleToken? = QwenProvider.classify(json("""
        {"code":"200","successResponse":true,
         "data":{"success":false,"errorCode":"PostOnlyOrTokenError","errorMsg":"request has expired"}}
        """)) {
            check("nested PostOnlyOrTokenError → staleToken", true)
        } else {
            check("nested PostOnlyOrTokenError → staleToken", false)
        }

        if case .loginRequired? = QwenProvider.classify(json("""
        {"successResponse":false,"errorCode":"NeedLogin","errorMsg":"please login"}
        """)) {
            check("NeedLogin → loginRequired", true)
        } else {
            check("NeedLogin → loginRequired", false)
        }

        // A workspace permission problem must not tell the user to re-paste a
        // cookie that is actually fine.
        if case .forbidden? = QwenProvider.classify(json("""
        {"successResponse":true,"data":{"success":false,
         "errorCode":"BailianGateway.Workspace.NotAuthorised","errorMsg":"not authorised"}}
        """)) {
            check("Workspace.NotAuthorised → forbidden", true)
        } else {
            check("Workspace.NotAuthorised → forbidden", false)
        }

        if case .api(let message)? = QwenProvider.classify(json("""
        {"successResponse":false,"errorCode":"Throttling","errorMsg":"too many requests"}
        """)) {
            check("unknown code → generic api error", message.contains("too many requests"), message)
        } else {
            check("unknown code → generic api error", false)
        }

        if case .loginRequired? = QwenProvider.classify(json("""
        {"successResponse":false,"statusCode":401,"message":"nope"}
        """)) {
            check("statusCode 401 → loginRequired", true)
        } else {
            check("statusCode 401 → loginRequired", false)
        }

        print("== Qwen HTML login page")
        let loginHTML = Data("<!DOCTYPE html><html><body><form>Please sign in</form></body></html>".utf8)
        do {
            _ = try QwenProvider.decode(loginHTML)
            check("login HTML → loginRequired", false, "no error thrown")
        } catch let failure as QwenFailure {
            if case .loginRequired = failure {
                check("login HTML → loginRequired", true)
            } else {
                check("login HTML → loginRequired", false, failure.message)
            }
        } catch {
            check("login HTML → loginRequired", false, "\(error)")
        }

        print("== Qwen usage payload (double-encoded envelope)")
        // The gateway double-encodes the payload: `data` is a JSON *string*.
        let inner = #"{\"success\":true,\"data\":{\"per5HourPercentage\":0.34,\"per1WeekPercentage\":0.7123,\"per5HourResetTime\":1754800000000,\"per1WeekResetTime\":\"2026-08-15 09:30:00\"}}"#
        let usage = json(#"{"code":"200","successResponse":true,"data":"\#(inner)"}"#)
        let windowObject = JSONWalk.findObject(in: usage, containing: ["per5HourPercentage", "per1WeekPercentage"])
        check("finds usage object through stringified JSON", windowObject != nil)
        check("5h ratio → 34%", QwenProvider.percent(fromRatio: num(windowObject?["per5HourPercentage"])) == 34)
        check("weekly ratio → 71.23%",
              (QwenProvider.percent(fromRatio: num(windowObject?["per1WeekPercentage"])) ?? 0) > 71.2)
        check("ms epoch reset parses", DateParse.parse(windowObject?["per5HourResetTime"]) != nil)
        check("'yyyy-MM-dd HH:mm:ss' reset parses", DateParse.parse(windowObject?["per1WeekResetTime"]) != nil)

        print("== Qwen plan + quota-config")
        let subscription = json("""
        {"successResponse":true,"data":{"success":true,"data":{"specCode":"Lite","status":"NORMAL"}}}
        """)
        check("plan code extracted", QwenProvider.planCode(from: subscription) == "lite")
        let quotaConfig = json("""
        {"successResponse":true,"data":{"success":true,
         "data":{"lite":{"five_hour":1000000,"weekly":20000000},
                 "pro":{"five_hour":5000000,"weekly":100000000}}}}
        """)
        let totals = QwenProvider.quotaTotals(from: quotaConfig, planCode: "lite")
        check("quota totals for the active plan", totals?.fiveHour == 1_000_000 && totals?.weekly == 20_000_000)
        check("no plan code → no totals", QwenProvider.quotaTotals(from: quotaConfig, planCode: nil) == nil)
        check("quota detail formatting",
              QwenProvider.quotaDetail(percent: 71, total: 20_000_000) == "14.2M / 20M",
              QwenProvider.quotaDetail(percent: 71, total: 20_000_000) ?? "nil")
        check("no total → no detail", QwenProvider.quotaDetail(percent: 71, total: nil) == nil)

        // Captured from the live Bailian gateway (intl region, standard plan) on
        // 2026-08-10. Values are shape-accurate; only identifiers were scrubbed.
        print("== Qwen live payload regression (captured 2026-08-10)")
        let liveUsage = json("""
        {"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS",
          "data":{"per1WeekResetTime":1786503720000,"per1WeekPercentage":1.0},
          "requestId":"scrubbed","success":true}},"success":true,"httpStatus":200,"errorCode":"",
          "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage","errorMsg":""},
         "httpStatusCode":"200","successResponse":true}
        """)
        check("live usage is not misread as an error", QwenProvider.classify(liveUsage) == nil)
        let liveWindow = JSONWalk.findObject(in: liveUsage, containing: ["per5HourPercentage", "per1WeekPercentage"])
        check("live usage object located", liveWindow != nil)
        // The real account has no 5-hour entry at all — the key is absent, not zero.
        check("absent 5h window → nil (no phantom row)",
              QwenProvider.percent(fromRatio: num(liveWindow?["per5HourPercentage"])) == nil)
        check("live weekly 1.0 → 100%", QwenProvider.percent(fromRatio: num(liveWindow?["per1WeekPercentage"])) == 100)
        check("live weekly reset parses", DateParse.parse(liveWindow?["per1WeekResetTime"]) != nil)

        let liveSubscription = json("""
        {"code":"200","data":{"DataV2":{"data":{"msg":"Success.","code":"SUCCESS",
          "data":{"instanceCode":"scrubbed","specCode":"standard","remainingDays":26,
                  "autoRenewFlag":false,"status":"VALID"},"success":true}},"success":true},
         "successResponse":true}
        """)
        check("live plan code = standard", QwenProvider.planCode(from: liveSubscription) == "standard")

        let liveQuota = json("""
        {"code":"200","data":{"DataV2":{"data":{"msg":"Success.","code":"SUCCESS",
          "data":{"standard":{"five_hour":3000.0,"weekly":10000.0},
                  "addon_quota":{"extrabundle":20000.0},
                  "lite":{"five_hour":700.0,"weekly":2500.0},
                  "pro":{"five_hour":12000.0,"weekly":40000.0}},"success":true}},"success":true},
         "successResponse":true}
        """)
        let liveTotals = QwenProvider.quotaTotals(from: liveQuota, planCode: "standard")
        check("live quota picks the active plan, not the first one",
              liveTotals?.fiveHour == 3_000 && liveTotals?.weekly == 10_000,
              "\(String(describing: liveTotals))")
        check("live detail renders unabbreviated",
              QwenProvider.quotaDetail(percent: 100, total: 10_000) == "10,000 / 10,000",
              QwenProvider.quotaDetail(percent: 100, total: 10_000) ?? "nil")

        print("== sec_token extraction")
        check("inline JSON token", QwenProvider.extractSecToken(html: #"window.ALIYUN={"secToken":"abc123"}"#) == "abc123")
        check("assignment form", QwenProvider.extractSecToken(html: "var sec_token = 'xyz789';") == "xyz789")
        check("login page yields no token",
              QwenProvider.extractSecToken(html: "<html><body>passport <form>login</form></body></html>") == nil)

        print("== formatting helpers")
        check("20M", NumberFormat.compact(20_000_000) == "20M", NumberFormat.compact(20_000_000))
        check("1.25M", NumberFormat.compact(1_250_000) == "1.25M", NumberFormat.compact(1_250_000))
        // Qwen's real quotas are 700..40,000, where abbreviating hurts readability.
        check("12,345 stays spelled out", NumberFormat.compact(12_345) == "12,345", NumberFormat.compact(12_345))
        check("3,000", NumberFormat.compact(3_000) == "3,000", NumberFormat.compact(3_000))
        check("340", NumberFormat.compact(340) == "340", NumberFormat.compact(340))
        let now = Date(timeIntervalSince1970: 1_000_000)
        check("2일 23시간", RelativeTime.resetText(now.addingTimeInterval(2 * 86_400 + 3600 * 23), now: now) == "2일 23시간 후 리셋",
              RelativeTime.resetText(now.addingTimeInterval(2 * 86_400 + 3600 * 23), now: now))
        check("59분", RelativeTime.resetText(now.addingTimeInterval(3_580), now: now) == "59분 후 리셋",
              RelativeTime.resetText(now.addingTimeInterval(3_580), now: now))
        check("과거는 곧 리셋", RelativeTime.resetText(now.addingTimeInterval(-10), now: now) == "곧 리셋")
        // The same instants must render in English when that language is active.
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Keys.language)
        check("en: resets in 2d 23h",
              RelativeTime.resetText(now.addingTimeInterval(2 * 86_400 + 3600 * 23), now: now) == "resets in 2d 23h",
              RelativeTime.resetText(now.addingTimeInterval(2 * 86_400 + 3600 * 23), now: now))
        check("en: resets in 59m",
              RelativeTime.resetText(now.addingTimeInterval(3_580), now: now) == "resets in 59m",
              RelativeTime.resetText(now.addingTimeInterval(3_580), now: now))
        check("en: resets soon", RelativeTime.resetText(now.addingTimeInterval(-10), now: now) == "resets soon")
        check("en: window name", S.windowWeekly.s == "Weekly", S.windowWeekly.s)
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: Keys.language)

        // NOTE: unlike every other provider here, these payloads are built from
        // the documented schema, not captured from a live account — there is no
        // Cursor session on this machine to record one from.
        print("== Cursor usage-summary (schema-derived)")
        func cursorJSON(_ text: String) -> [String: Any] {
            (try! JSONSerialization.jsonObject(with: Data(text.utf8))) as! [String: Any]
        }
        let cursorPro = cursorJSON("""
        {"membershipType":"pro","billingCycleStart":"2026-08-01T00:00:00Z",
         "billingCycleEnd":"2026-09-01T00:00:00Z","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":1250,"limit":2000,"remaining":750,
           "totalPercentUsed":62.5},"onDemand":{"enabled":false,"used":0,"limit":null}}}
        """)
        if case .ok(let plan, let windows, let reached, _) = CursorProvider.parse(cursorPro) {
            check("plan name", plan == "Pro", plan ?? "nil")
            check("one window (on-demand disabled)", windows.count == 1, "\(windows.count)")
            check("uses Cursor's own percentage", windows.first?.percent == 62.5)
            // Values are cents: 1250 -> $12.50, not $1250.
            check("cents rendered as dollars", windows.first?.detail == "$12.50 / $20",
                  windows.first?.detail ?? "nil")
            check("billing cycle end is the reset", windows.first?.resetsAt != nil)
            check("not limit-reached at 62.5%", reached == false)
        } else {
            check("pro payload parses", false)
        }

        let cursorMaxed = cursorJSON("""
        {"membershipType":"pro_plus",
         "individualUsage":{"plan":{"enabled":true,"used":6000,"limit":6000},
          "onDemand":{"enabled":true,"used":1500,"limit":5000}}}
        """)
        if case .ok(let plan, let windows, let reached, _) = CursorProvider.parse(cursorMaxed) {
            check("Pro+ label", plan == "Pro+", plan ?? "nil")
            check("on-demand adds a window", windows.count == 2, "\(windows.count)")
            // No totalPercentUsed here, so it must fall back to used/limit.
            check("falls back to used/limit", windows.first?.percent == 100)
            check("limit reached", reached == true)
            check("on-demand detail", windows.last?.detail == "$15 / $50", windows.last?.detail ?? "nil")
        } else {
            check("maxed payload parses", false)
        }

        // Uncapped on-demand has no meaningful percentage, so it must be skipped
        // rather than shown as 0% or 100%.
        let cursorUncapped = cursorJSON("""
        {"membershipType":"ultra",
         "individualUsage":{"plan":{"enabled":true,"used":100,"limit":2000},
          "onDemand":{"enabled":true,"used":9999,"limit":null}}}
        """)
        if case .ok(_, let windows, _, let note) = CursorProvider.parse(cursorUncapped) {
            check("uncapped on-demand becomes a note", note?.contains("한도 없음") == true, note ?? "nil")
            check("uncapped on-demand skipped", windows.count == 1, "\(windows.count)")
        } else {
            check("uncapped payload parses", false)
        }

        // Team members report a personal cap under `overall` instead of `plan`.
        let cursorTeam = cursorJSON("""
        {"membershipType":"enterprise",
         "individualUsage":{"overall":{"enabled":true,"used":7384,"limit":10000}}}
        """)
        if case .ok(let plan, let windows, _, _) = CursorProvider.parse(cursorTeam) {
            check("enterprise personal cap", windows.first?.name == "개인 한도", windows.first?.name ?? "nil")
            check("cap percentage", (windows.first?.percent).map { abs($0 - 73.84) < 0.01 } == true)
            check("enterprise label", plan == "Enterprise", plan ?? "nil")
        } else {
            check("team payload parses", false)
        }

        if case .ok(_, let windows, _, _) = CursorProvider.parse(cursorJSON(
            #"{"membershipType":"ultra","isUnlimited":true,"individualUsage":{}}"#)) {
            check("unlimited plan → no windows, still OK", windows.isEmpty)
        } else {
            check("unlimited plan → no windows, still OK", false)
        }
        if case .error = CursorProvider.parse(cursorJSON(#"{"membershipType":"pro"}"#)) {
            check("no usage block at all → error", true)
        } else {
            check("no usage block at all → error", false)
        }

        // Captured live from a Free account on 2026-08-10: the plan bucket exists
        // but reports limit 0, which is not an error and must not draw a 0% bar.
        let cursorFree = cursorJSON("""
        {"billingCycleStart":"2026-07-23T02:23:47.444Z","billingCycleEnd":"2026-08-23T02:23:47.444Z",
         "membershipType":"free","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
           "breakdown":{"included":0,"bonus":0,"total":0},
           "autoPercentUsed":0,"apiPercentUsed":0,"totalPercentUsed":0},
          "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
         "teamUsage":{}}
        """)
        if case .ok(let plan, let windows, let reached, let note) = CursorProvider.parse(cursorFree) {
            check("live Free plan → Free badge", plan == "Free", plan ?? "nil")
            check("live Free plan draws no bar", windows.isEmpty, "\(windows.count)")
            check("live Free plan explains why", note?.contains("포함된 사용량이 없어요") == true, note ?? "nil")
            check("live Free plan is not limit-reached", reached == false)
        } else {
            check("live Free payload parses", false)
        }

        print("== menu bar icon scales with provider count")
        for count in 1...4 {
            let entries = (0..<count).map { _ in MeterIcon.Entry(percent: 50, color: .systemGreen) }
            let width = MeterIcon.image(entries: entries).size.width
            let expected: CGFloat = count <= 2 ? CGFloat(count) * 5 + CGFloat(count - 1) * 3
                                               : CGFloat(count) * 4 + CGFloat(count - 1) * 3
            check("\(count)개 → \(Int(width))pt", width == expected, "\(width) vs \(expected)")
        }
        check("0개 → 미설정 아이콘", MeterIcon.image(entries: []).size.width == 18)
        check("색: 40% 초록", MeterIcon.color(for: 40) == .systemGreen)
        check("색: 60% 주황", MeterIcon.color(for: 60) == .systemOrange)
        check("색: 90% 빨강", MeterIcon.color(for: 90) == .systemRed)

        print("== 로컬라이제이션")
        // Both translations are required by the type, so the risk is not a
        // missing string but an accidentally identical or empty one.
        let allStrings: [(String, Localized)] = [
            ("appTitle", S.appTitle), ("loading", S.loading), ("limitReached", S.limitReached),
            ("noUsageData", S.noUsageData), ("setUpCookie", S.setUpCookie),
            ("windowFiveHour", S.windowFiveHour), ("windowWeekly", S.windowWeekly),
            ("windowPlan", S.windowPlan), ("windowOnDemand", S.windowOnDemand),
            ("claudeExpired", S.claudeExpired), ("openAINoUsage", S.openAINoUsage),
            ("cursorNoIncludedUsage", S.cursorNoIncludedUsage), ("qwenNeedCookie", S.qwenNeedCookie),
            ("settingsWindowTitle", S.settingsWindowTitle), ("menuBarProviderHelp", S.menuBarProviderHelp),
            ("sectionServices", S.sectionServices), ("servicesHelp", S.servicesHelp),
            ("noServicesEnabled", S.noServicesEnabled),
            ("qwenAutoHelp", S.qwenAutoHelp), ("qwenManualHelp", S.qwenManualHelp),
            ("importNow", S.importNow), ("save", S.save), ("delete", S.delete),
        ]
        check("모든 문자열이 비어 있지 않음",
              allStrings.allSatisfy { !$0.1.ko.isEmpty && !$0.1.en.isEmpty },
              allStrings.filter { $0.1.ko.isEmpty || $0.1.en.isEmpty }.map(\.0).joined(separator: ", "))
        // Proper nouns legitimately match; prose must not.
        let untranslated = allStrings.filter { $0.1.ko == $0.1.en }.map(\.0)
        check("번역이 실제로 다름", untranslated.isEmpty, untranslated.joined(separator: ", "))
        check("한국어 문자열에 한글 포함",
              allStrings.allSatisfy { $0.1.ko.range(of: "\\p{Hangul}", options: .regularExpression) != nil },
              allStrings.filter { $0.1.ko.range(of: "\\p{Hangul}", options: .regularExpression) == nil }
                  .map(\.0).joined(separator: ", "))
        check("영어 문자열에 한글 없음",
              allStrings.allSatisfy { $0.1.en.range(of: "\\p{Hangul}", options: .regularExpression) == nil },
              allStrings.filter { $0.1.en.range(of: "\\p{Hangul}", options: .regularExpression) != nil }
                  .map(\.0).joined(separator: ", "))
        check("시스템 기본값은 ko/en 중 하나",
              [AppLanguage.korean, .english].contains(AppLanguage.systemDefault))
        check("알 수 없는 코드는 무시", AppLanguage(rawValue: "fr") == nil)

        print("== Cursor 로컬 세션 (앱 DB)")
        func fakeJWT(sub: String, exp: Double) -> String {
            func b64(_ dict: [String: Any]) -> String {
                let data = try! JSONSerialization.data(withJSONObject: dict)
                return data.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return "\(b64(["alg": "RS256"])).\(b64(["sub": sub, "exp": exp, "aud": "https://cursor.com"])).sig"
        }
        let jwt = fakeJWT(sub: "google-oauth2|user_TEST", exp: 4_000_000_000)
        check("JWT sub 추출", CursorLocalAuth.jwtClaim(jwt, "sub") as? String == "google-oauth2|user_TEST")
        check("JWT exp 추출", (CursorLocalAuth.jwtClaim(jwt, "exp") as? NSNumber)?.doubleValue == 4_000_000_000)
        check("JWT 아닌 값 → nil", CursorLocalAuth.jwtClaim("not-a-jwt", "sub") == nil)
        check("조각 수가 틀리면 nil", CursorLocalAuth.jwtClaim("a.b", "sub") == nil)
        // The web API rejects a bare bearer token; it needs `{sub}::{jwt}`.
        let live = CursorLocalAuth.Session(
            cookieHeader: "WorkosCursorSessionToken=google-oauth2|user_TEST::\(jwt)",
            membershipType: "free", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        check("세션 쿠키는 sub::jwt 형식", live.cookieHeader.contains("user_TEST::"), live.cookieHeader.prefix(48).description)
        check("유효한 세션은 만료 아님", live.isExpired == false)
        let staleSession = CursorLocalAuth.Session(cookieHeader: "x", membershipType: nil,
                                                   expiresAt: Date(timeIntervalSinceNow: -10))
        check("만료된 세션 감지", staleSession.isExpired == true)
        let noExpiry = CursorLocalAuth.Session(cookieHeader: "x", membershipType: nil, expiresAt: nil)
        check("만료 정보 없으면 유효 취급", noExpiry.isExpired == false)

        print("== 안 쓰는 서비스 끄기")
        let previousDisabled = UserDefaults.standard.stringArray(forKey: Keys.disabledProviders)
        let roster = ProviderRoster.listing.map(\.id)
        ProviderVisibility.disabledIDs = []
        check("기본값은 전부 켜짐", ProviderRoster.enabled().map(\.id) == roster,
              ProviderRoster.enabled().map(\.id).joined(separator: ","))
        ProviderVisibility.disabledIDs = ["cursor", "qwen"]
        // Switched-off services must drop out before the fetch, not after: the
        // point is to stop querying them at all.
        check("꺼진 서비스는 조회 대상에서 빠짐",
              ProviderRoster.enabled().map(\.id) == ["claude", "openai"],
              ProviderRoster.enabled().map(\.id).joined(separator: ","))
        check("전체 목록은 그대로 (설정에서 다시 켤 수 있어야 함)",
              ProviderRoster.listing.count == roster.count)
        check("설정은 재시작 후에도 유지",
              ProviderVisibility.disabledIDs == ["cursor", "qwen"])
        check("모르는 id는 아무 영향 없음", { () -> Bool in
            ProviderVisibility.disabledIDs = ["not-a-provider"]
            return ProviderRoster.enabled().map(\.id) == roster
        }())
        ProviderVisibility.disabledIDs = Set(roster)
        check("전부 끄면 조회 대상 없음", ProviderRoster.enabled().isEmpty)
        ProviderVisibility.disabledIDs = []
        check("전부 켜면 저장 키를 지움",
              UserDefaults.standard.object(forKey: Keys.disabledProviders) == nil)
        if let previousDisabled {
            UserDefaults.standard.set(previousDisabled, forKey: Keys.disabledProviders)
        }

        print("== 갱신은 기본적으로 비대화식")
        // The bug this pins: a settings change refreshed as "user initiated",
        // which arms an interactive Keychain read. Nobody answers an approval
        // dialog they did not ask for, so the read parked for its whole timeout —
        // menu bar icon spinning throughout, and the global interaction lock held
        // long enough to freeze the Settings window that opened behind it.
        check("기본 로스터는 Keychain 프롬프트를 켜지 않음",
              (ProviderRoster.all().first as? ClaudeProvider)?.userInitiated == false)
        check("Qwen도 마찬가지", (ProviderRoster.all().last as? QwenProvider)?.userInitiated == false)
        check("명시적 사용자 동작만 대화식",
              (ProviderRoster.all(userInitiated: true).first as? ClaudeProvider)?.userInitiated == true)

        print("== 요금제 배지 유지")
        let probe = CursorProvider()
        AppStore.PlanCache.forget(probe.id)
        _ = AppStore.makeSnapshot(provider: probe,
                                  result: .ok(planName: "Pro", windows: [], limitReached: false))
        // A failing fetch must not blank the badge: the subscription tier did not
        // change just because one request timed out.
        let afterError = AppStore.makeSnapshot(provider: probe, result: .error("일시적 오류"))
        check("오류 시 배지 유지", afterError.planName == "Pro", afterError.planName ?? "nil")
        // Disconnected is different — a stale tier there would be wrong.
        let afterSetup = AppStore.makeSnapshot(provider: probe, result: .needsSetup("로그인 필요"))
        check("미설정 시 배지 제거", afterSetup.planName == nil, afterSetup.planName ?? "nil")
        let afterForget = AppStore.makeSnapshot(provider: probe, result: .error("일시적 오류"))
        check("미설정 후에는 되살아나지 않음", afterForget.planName == nil, afterForget.planName ?? "nil")
        AppStore.PlanCache.forget(probe.id)

        print("== Claude credentials")
        let keychainShape = ClaudeCredentials.parse(Data("""
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1786357294282,
          "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max"}}
        """.utf8), source: "Keychain")
        check("keychain payload parses", keychainShape?.accessToken == "tok")
        check("subscriptionType read", keychainShape?.subscriptionType == "max")
        check("expiresAt (ms epoch) parsed", keychainShape?.expiresAt != nil)
        // The bug this fixes: the on-disk file held a token that expired days earlier.
        let stale = ClaudeCredentials.parse(Data("""
        {"claudeAiOauth":{"accessToken":"tok","expiresAt":1785919027011}}
        """.utf8), source: "file")
        check("expired credential is detected", stale?.isExpired == true)
        check("garbage payload → nil", ClaudeCredentials.parse(Data("{}".utf8), source: "x") == nil)
        check("plan display: max → Max", ClaudeProvider.planDisplay("max") == "Max")
        check("plan display strips vendor prefix",
              ClaudeProvider.planDisplay("default_claude_max_5x") == "Max 5x",
              ClaudeProvider.planDisplay("default_claude_max_5x") ?? "nil")
        check("plan display: nil → nil", ClaudeProvider.planDisplay(nil) == nil)

        // Captured from the live endpoint on 2026-08-10.
        let claudeUsage = (try! JSONSerialization.jsonObject(with: Data("""
        {"five_hour":{"utilization":25.0,"resets_at":"2026-08-10T07:19:59.112066+00:00"},
         "seven_day":{"utilization":2.0,"resets_at":"2026-08-16T19:59:59.112087+00:00"},
         "seven_day_opus":null,
         "limits":[{"kind":"session","percent":25,"resets_at":"2026-08-10T07:19:59.112066+00:00","scope":null},
                   {"kind":"weekly_all","percent":2,"resets_at":"2026-08-16T19:59:59.112087+00:00","scope":null},
                   {"kind":"weekly_scoped","percent":0,"resets_at":null,
                    "scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8)) as! [String: Any])
        let claudeWindows = ClaudeProvider.parseWindows(claudeUsage)
        check("live Claude → 3 windows", claudeWindows.count == 3, "\(claudeWindows.count)")
        check("utilization is percentage points, not a ratio", claudeWindows.first?.percent == 25)
        check("fractional-seconds ISO reset parses", claudeWindows.first?.resetsAt != nil)
        check("model-scoped window is named", claudeWindows.last?.name == "주간 · Fable",
              claudeWindows.last?.name ?? "nil")

        print("== Claude rate-limit gate")
        let gateToken = "selftest-token"
        ClaudeRateLimitGate.clear(token: gateToken)
        check("clean gate does not block", ClaudeRateLimitGate.blockedUntil(token: gateToken) == nil)
        check("Retry-After seconds parsed",
              ClaudeRateLimitGate.parseRetryAfter("2703", now: Date(timeIntervalSince1970: 0))
                  == Date(timeIntervalSince1970: 2703))
        check("Retry-After HTTP-date parsed",
              ClaudeRateLimitGate.parseRetryAfter("Mon, 10 Aug 2026 03:00:00 GMT") != nil)
        check("garbage Retry-After → nil", ClaudeRateLimitGate.parseRetryAfter("soon") == nil)
        ClaudeRateLimitGate.record(token: gateToken, retryAfter: Date().addingTimeInterval(600))
        check("gate blocks after a 429", ClaudeRateLimitGate.blockedUntil(token: gateToken) != nil)
        ClaudeRateLimitGate.record(token: gateToken, retryAfter: Date().addingTimeInterval(-10))
        check("past Retry-After falls back to a default cooldown",
              ClaudeRateLimitGate.blockedUntil(token: gateToken) != nil)
        ClaudeRateLimitGate.clear(token: gateToken)
        check("success clears the gate", ClaudeRateLimitGate.blockedUntil(token: gateToken) == nil)

        print("== Chromium cookie decryption")
        // Round-trip through the exact scheme Chromium uses: PBKDF2-SHA1 key,
        // AES-128-CBC, 16-space IV, PKCS#7 padding, 32-byte host-hash prefix.
        let cryptoKey = BrowserCookies.testDeriveKey("peanuts")
        let secret = "login_aliyunid_ticket_value"
        let blob = BrowserCookies.testEncrypt(secret, key: cryptoKey, plaintextOffset: 32)
        check("v10 blob decrypts", BrowserCookies.decrypt(blob, key: cryptoKey, plaintextOffset: 32) == secret,
              BrowserCookies.decrypt(blob, key: cryptoKey, plaintextOffset: 32) ?? "nil")
        check("wrong key → nil or garbage, never a crash",
              BrowserCookies.decrypt(blob, key: BrowserCookies.testDeriveKey("wrong"), plaintextOffset: 32) != secret)
        check("non-v10 blob rejected",
              BrowserCookies.decrypt(Data("v20abcdefghijklmno".utf8), key: cryptoKey, plaintextOffset: 32) == nil)
        check("truncated blob rejected", BrowserCookies.decrypt(Data("v10".utf8), key: cryptoKey, plaintextOffset: 0) == nil)
        check("legacy schema (no host prefix) decrypts",
              BrowserCookies.decrypt(BrowserCookies.testEncrypt(secret, key: cryptoKey, plaintextOffset: 0),
                                     key: cryptoKey, plaintextOffset: 0) == secret)

        print("== cookie extraction")
        let curl = """
        curl 'https://bailian.console.aliyun.com/data/api.json' \\
          -H 'accept: application/json' \\
          -H 'cookie: cna=abc; login_aliyunid_csrf=tok123; sec_token=zzz' \\
          --data-raw 'x=1'
        """
        check("cURL → cookie header", CookieExtract.extract(from: curl) == "cna=abc; login_aliyunid_csrf=tok123; sec_token=zzz",
              CookieExtract.extract(from: curl) ?? "nil")
        check("cookie value lookup",
              QwenProvider.cookieValue("cna=abc; login_aliyunid_csrf=tok123", name: "login_aliyunid_csrf") == "tok123")
        check("missing cookie → nil", QwenProvider.cookieValue("cna=abc", name: "sec_token") == nil)

        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) self-test(s) failed.")
        return failures
    }
}
#endif
