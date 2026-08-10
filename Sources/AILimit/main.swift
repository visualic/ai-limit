import AppKit
import Foundation

if CommandLine.arguments.contains("--check") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        // Non-interactive on purpose: a Keychain approval dialog cannot be
        // answered from a shell-launched process, so asking would just stall.
        let providers: [UsageProvider] = [
            ClaudeProvider(), OpenAIProvider(), CursorProvider(), QwenProvider(),
        ]
        for provider in providers {
            let result = await provider.fetch()
            print("== \(provider.displayName) (\(provider.id))")
            switch result {
            case .ok(let planName, let windows, let limitReached, let note):
                print("   plan: \(planName ?? "-")  limitReached: \(limitReached)")
                if let note { print("   note: \(note)") }
                for window in windows {
                    let reset = window.resetsAt.map { RelativeTime.resetText($0) } ?? "-"
                    let detail = window.detail.map { " [\($0)]" } ?? ""
                    print("   \(window.name): \(Int(window.percent.rounded()))%\(detail) (\(reset))")
                }
            case .error(let message):
                print("   ERROR: \(message)")
            case .needsSetup(let message):
                print("   SETUP: \(message)")
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

#if DEBUG
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--import-cookies") {
    let interactive = CommandLine.arguments.contains("--interactive")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let region = QwenRegionConfig.current()
        let result = await BrowserCookies.importSessionAsync(
            domains: [region.cookieDomain],
            requiredCookies: QwenProvider.requiredCookies,
            allowInteraction: interactive,
            timeout: 45
        )
        switch result {
        case .success(let imported):
            Keychain.save(imported.cookieHeader, account: Keys.qwenCookieAuto)
            print("OK  source=\(imported.sourceLabel)  cookies=\(imported.cookieNames.count)")
            print("    names: \(imported.cookieNames.prefix(8).joined(separator: ", "))…")
            print("    saved to Keychain as \(Keys.qwenCookieAuto)")
        case .failure(let error):
            print("FAIL \(error.errorDescription ?? "?")")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if CommandLine.arguments.contains("--screenshot") {
    MainActor.assumeIsolated { Screenshot.run(directory: "docs") }
    exit(0)
}

if CommandLine.arguments.contains("--icon-preview") {
    MainActor.assumeIsolated { IconPreview.run(output: "/tmp/ailimit-icons.png") }
    exit(0)
}

if CommandLine.arguments.contains("--preview-app") {
    let settings = CommandLine.arguments.contains("--settings")
    let live = CommandLine.arguments.contains("--live")
    let output = settings ? "/tmp/ailimit-settings.png"
        : (live ? "/tmp/ailimit-popover-live.png" : "/tmp/ailimit-popover-app.png")
    MainActor.assumeIsolated { AppPreview.run(output: output, settings: settings, live: live) }
    exit(0)
}

if CommandLine.arguments.contains("--preview") {
    let useErrorMocks = CommandLine.arguments.contains("--errors")
    let output = useErrorMocks ? "/tmp/ailimit-popover-errors.png" : "/tmp/ailimit-popover.png"
    MainActor.assumeIsolated { UIPreview.run(useErrorMocks: useErrorMocks, output: output) }
    exit(0)
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
