import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var cookie: String = ""
    @State private var testMessage: String?
    @State private var testing = false
    @State private var importMessage: String?
    @State private var importing = false
    @State private var cursorImportMessage: String?
    @State private var cursorImporting = false

    private var intervals: [(String, TimeInterval)] {
        [(S.minutes(1), 60), (S.minutes(3), 180), (S.minutes(5), 300),
         (S.minutes(15), 900), (S.minutes(30), 1800)]
    }

    var body: some View {
        Form {
            Section(S.sectionGeneral.s) {
                Picker(S.refreshInterval.s, selection: $store.refreshInterval) {
                    ForEach(intervals, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Picker(S.language.s, selection: $store.language) {
                    Text(S.languageSystem.s).tag("")
                    Text(S.languageKorean.s).tag(AppLanguage.korean.rawValue)
                    Text(S.languageEnglish.s).tag(AppLanguage.english.rawValue)
                }

                Toggle(S.showPercent.s, isOn: $store.showPercent)

                if store.showPercent {
                    Picker(S.menuBarProvider.s, selection: menuBarProviderBinding) {
                        ForEach(store.snapshots.filter { !$0.needsSetup }) { snapshot in
                            Text(snapshot.displayName).tag(snapshot.id)
                        }
                        Divider()
                        Text(S.highestValue.s).tag(AppDelegate.highestValueToken)
                    }
                    Text(S.menuBarProviderHelp.s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(S.sectionServices.s) {
                ForEach(ProviderRoster.listing) { provider in
                    Toggle(provider.displayName, isOn: enabledBinding(provider.id))
                }
                Text(S.servicesHelp.s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The setup sections below belong to one service each, so they follow
            // its toggle: configuring a service you switched off is dead UI.
            if store.isEnabled("cursor") {
                Section(S.sectionCursor.s) {
                    Text(S.cursorHelp.s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        probeCursorImport()
                    } label: {
                        Label(S.importNow.s, systemImage: "arrow.down.circle")
                    }
                    .disabled(cursorImporting)

                    if let cursorImportMessage {
                        Text(cursorImportMessage)
                            .font(.caption)
                            .foregroundStyle(cursorImportMessage.hasPrefix(S.successPrefix) ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        if let url = URL(string: "https://cursor.com/dashboard") { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(S.openCursorDashboard.s, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if store.isEnabled("qwen") {
                Section(S.sectionQwen.s) {
                    Picker(S.region.s, selection: qwenRegionBinding) {
                        Text(S.regionIntl.s).tag("intl-personal")
                        Text(S.regionChina.s).tag("cn-personal")
                    }

                    Picker(S.cookieSource.s, selection: cookieSourceBinding) {
                        Text(S.cookieSourceAuto.s).tag("auto")
                        Text(S.cookieSourceManual.s).tag("manual")
                    }

                    if cookieSourceBinding.wrappedValue == "auto" {
                        Text(S.qwenAutoHelp.s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            probeImport()
                        } label: {
                            Label(S.importNow.s, systemImage: "arrow.down.circle")
                        }
                        .disabled(importing)

                        if let importMessage {
                            Text(importMessage)
                                .font(.caption)
                                .foregroundStyle(importMessage.hasPrefix(S.successPrefix) ? Color.green : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        openConsole()
                    } label: {
                        Label(
                            cookieSourceBinding.wrappedValue == "auto"
                                ? S.openTokenPlanBrowser.s
                                : S.openTokenPlanCopy.s,
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)

                    if cookieSourceBinding.wrappedValue == "manual" {
                        Text(S.qwenManualHelp.s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextEditor(text: $cookie)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

                        Text(S.pasteHint.s)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 8) {
                            Button(S.save.s) { save() }
                                .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(S.testConnection.s) { test() }
                                .disabled(testing || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(S.delete.s, role: .destructive) {
                                Keychain.delete(Keys.qwenCookie)
                                AppStore.PlanCache.forget("qwen")
                                cookie = ""
                                testMessage = nil
                                Task {
                                    await QwenSecTokenCache.shared.invalidateAll()
                                    await MainActor.run { store.refresh() }
                                }
                            }
                            Spacer()
                            if testing {
                                ProgressView().controlSize(.small)
                            }
                        }

                        if let message = testMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(message.hasPrefix(S.successPrefix) ? Color.green : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .onAppear {
            cookie = Keychain.load(Keys.qwenCookie, allowInteraction: true) ?? ""
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.isEnabled(id) },
            set: { store.setProvider(id, enabled: $0) }
        )
    }

    private var menuBarProviderBinding: Binding<String> {
        Binding(
            get: {
                let stored = UserDefaults.standard.string(forKey: Keys.menuBarProvider) ?? ""
                // The stored choice is kept even while it has no row to select —
                // switching that service back on restores the picker to it — so
                // fall back for display rather than rewriting the preference.
                if stored == AppDelegate.highestValueToken
                    || store.snapshots.contains(where: { $0.id == stored && !$0.needsSetup }) {
                    return stored
                }
                // Default to the first configured provider, not the maximum.
                return store.snapshots.first { !$0.needsSetup }?.id ?? AppDelegate.highestValueToken
            },
            set: { UserDefaults.standard.set($0, forKey: Keys.menuBarProvider) }
        )
    }

    /// Runs the real Cursor import so the user can grant Keychain access and see
    /// which browser profile answered.
    private func probeCursorImport() {
        cursorImporting = true
        cursorImportMessage = nil
        Task {
            let result = await BrowserCookies.importSessionAsync(
                domains: CursorProvider.cookieDomains,
                requiredCookies: CursorProvider.requiredCookies,
                allowInteraction: true,
                timeout: 45
            )
            await BrowserSessionCache.shared.invalidateAll()
            await MainActor.run {
                switch result {
                case .success(let imported):
                    Keychain.save(imported.cookieHeader, account: Keys.cursorCookieAuto)
                    cursorImportMessage = S.importSucceeded(imported.sourceLabel, imported.cookieNames.count)
                case .failure(let error):
                    cursorImportMessage = S.importFailed(error.errorDescription ?? S.unknownError.s)
                }
                cursorImporting = false
                store.refresh(userInitiated: true)
            }
        }
    }

    private var cookieSourceBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: Keys.qwenCookieSource) ?? "auto" },
            set: {
                UserDefaults.standard.set($0, forKey: Keys.qwenCookieSource)
                importMessage = nil
                store.refresh(userInitiated: true)
            }
        )
    }

    /// Runs the real import path so the user can see which browser profile it
    /// picked up before trusting it.
    private func probeImport() {
        importing = true
        importMessage = nil
        let region = QwenRegionConfig.current()
        Task {
            // The explicit button is the one place a Keychain approval dialog is
            // appropriate; approving once lets background refreshes read it silently.
            let result = await BrowserCookies.importSessionAsync(
                domains: [region.cookieDomain],
                requiredCookies: QwenProvider.requiredCookies,
                allowInteraction: true,
                timeout: 45
            )
            await BrowserSessionCache.shared.invalidateAll()
            await MainActor.run {
                switch result {
                case .success(let imported):
                    Keychain.save(imported.cookieHeader, account: Keys.qwenCookieAuto)
                    importMessage = S.importSucceeded(imported.sourceLabel, imported.cookieNames.count)
                case .failure(let error):
                    importMessage = S.importFailed(error.errorDescription ?? S.unknownError.s)
                }
                importing = false
                store.refresh(userInitiated: true)
            }
        }
    }

    private var qwenRegionBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: Keys.qwenRegion) ?? "intl-personal" },
            set: { region in
                UserDefaults.standard.set(region, forKey: Keys.qwenRegion)
                // The cached sec_token and plan badge belong to the old region.
                AppStore.PlanCache.forget("qwen")
                Task {
                    await QwenSecTokenCache.shared.invalidateAll()
                    await MainActor.run { store.refresh() }
                }
            }
        )
    }

    private func openConsole() {
        guard let url = URL(string: QwenRegionConfig.current().dashboardURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func save() {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let extracted = CookieExtract.extract(from: raw) else {
            testMessage = S.cookieNotFound.s
            return
        }
        Keychain.save(extracted, account: Keys.qwenCookie)
        testMessage = nil
        store.refresh()
    }

    private func test() {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let extracted = CookieExtract.extract(from: raw) else {
            testMessage = S.cookieNotFound.s
            return
        }
        testing = true
        testMessage = nil
        Task {
            let result = await QwenProvider(cookieOverride: extracted).fetch()
            await MainActor.run {
                switch result {
                case .ok(let plan, let windows, _, _):
                    let summary = windows
                        .map { window in
                            let detail = window.detail.map { " (\($0))" } ?? ""
                            return "\(window.name) \(Int(window.percent.rounded()))%\(detail)"
                        }
                        .joined(separator: ", ")
                    testMessage = S.testSucceeded(plan ?? "-", summary)
                case .error(let message):
                    testMessage = S.importFailed(message)
                case .needsSetup(let message):
                    testMessage = S.importFailed(message)
                }
                testing = false
            }
        }
    }
}
