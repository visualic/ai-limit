import Foundation
import CommonCrypto
import SQLite3
import Security

/// Reads cookies out of a locally installed Chromium browser so the user does not
/// have to hand-copy a Cookie header.
///
/// Chromium on macOS stores cookies in a SQLite database with each value encrypted
/// as `"v10" + AES-128-CBC(key, iv: 16 spaces)`. The key is PBKDF2-SHA1 over a
/// random passphrase the browser keeps in the login Keychain under
/// `<Browser> Safe Storage`. This is the classic scheme; macOS builds do not yet
/// use the app-bound encryption that Chromium ships on Windows (`v20`), which is
/// why manual paste has to stay available as a fallback.
enum BrowserCookies {

    struct Browser {
        let name: String
        /// Directory under ~/Library/Application Support holding the profiles.
        let supportPath: String
        /// Keychain generic-password service holding the encryption passphrase.
        let keychainService: String
        /// Keychain account for that item.
        let keychainAccount: String

        static let all: [Browser] = [
            Browser(name: "Chrome", supportPath: "Google/Chrome",
                    keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
            Browser(name: "Chrome Beta", supportPath: "Google/Chrome Beta",
                    keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
            Browser(name: "Chrome Canary", supportPath: "Google/Chrome Canary",
                    keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
            Browser(name: "Brave", supportPath: "BraveSoftware/Brave-Browser",
                    keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
            Browser(name: "Edge", supportPath: "Microsoft Edge",
                    keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
            Browser(name: "Arc", supportPath: "Arc/User Data",
                    keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
            Browser(name: "Vivaldi", supportPath: "Vivaldi",
                    keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
            Browser(name: "Chromium", supportPath: "Chromium",
                    keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
        ]
    }

    struct ImportResult {
        let cookieHeader: String
        /// e.g. `Chrome · Default` — shown so the user knows where it came from.
        let sourceLabel: String
        let cookieNames: [String]
    }

    enum ImportError: LocalizedError, Equatable {
        case noBrowserFound
        case keychainDenied(String)
        case noMatchingCookies(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBrowserFound:
                return S.browserNotFound.s
            case .keychainDenied(let browser):
                return S.keychainDenied(browser)
            case .noMatchingCookies(let browser):
                return S.noMatchingCookies(browser)
            case .readFailed(let detail):
                return S.cookieReadFailed(detail)
            }
        }
    }

    /// Runs the (blocking) import off the Swift concurrency cooperative pool.
    ///
    /// `keychainPassphrase` can park in a synchronous Mach round-trip to securityd
    /// while it waits on an access decision. Doing that on a cooperative thread
    /// wedged the whole refresh — the popover sat on its loading state forever.
    static func importSessionAsync(
        domains: [String],
        requiredCookies: [String],
        allowInteraction: Bool,
        timeout: TimeInterval = 20
    ) async -> Result<ImportResult, ImportError> {
        await withCheckedContinuation { continuation in
            let resumed = NSLock()
            nonisolated(unsafe) var hasResumed = false
            func finish(_ result: Result<ImportResult, ImportError>) {
                resumed.lock()
                let alreadyResumed = hasResumed
                hasResumed = true
                resumed.unlock()
                if !alreadyResumed { continuation.resume(returning: result) }
            }
            // A stuck approval dialog must not hold the refresh open forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(.keychainDenied(S.browserGeneric.s)))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(importSession(
                    domains: domains, requiredCookies: requiredCookies, allowInteraction: allowInteraction
                ))
            }
        }
    }

    /// Tries each installed browser in order and returns the first profile that
    /// holds a usable console session.
    ///
    /// - Parameter allowInteraction: when false, a Keychain item whose ACL does
    ///   not already trust this app fails fast instead of raising an approval
    ///   dialog. Background refreshes pass false so they can never block on UI;
    ///   only the explicit settings button asks the user.
    /// - Parameter requiredCookies: names that must all be present for the session
    ///   to count. Without this check a logged-out profile imports "successfully"
    ///   and then fails every API call.
    static func importSession(
        domains: [String],
        requiredCookies: [String],
        allowInteraction: Bool = false
    ) -> Result<ImportResult, ImportError> {
        Keychain.withInteraction(allowInteraction) {
            importSessionLocked(domains: domains, requiredCookies: requiredCookies)
        }
    }

    private static func importSessionLocked(
        domains: [String],
        requiredCookies: [String]
    ) -> Result<ImportResult, ImportError> {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        var sawBrowser = false
        var lastFailure: ImportError?

        for browser in Browser.all {
            let root = support.appendingPathComponent(browser.supportPath)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            sawBrowser = true

            guard let passphrase = keychainPassphrase(browser) else {
                // Keep the *first* denial: browsers are ordered by likelihood, so
                // naming Chrome is more useful than naming whichever stub profile
                // happened to be checked last.
                if lastFailure == nil { lastFailure = .keychainDenied(browser.name) }
                continue
            }
            let key = deriveKey(passphrase)

            for profile in profileDatabases(in: root) {
                do {
                    let jar = try readCookies(at: profile.url, key: key, domains: domains)
                    guard requiredCookies.allSatisfy({ jar[$0]?.isEmpty == false }) else {
                        lastFailure = .noMatchingCookies(browser.name)
                        continue
                    }
                    let header = jar.keys.sorted().map { "\($0)=\(jar[$0]!)" }.joined(separator: "; ")
                    return .success(ImportResult(
                        cookieHeader: header,
                        sourceLabel: "\(browser.name) · \(profile.name)",
                        cookieNames: jar.keys.sorted()
                    ))
                } catch {
                    lastFailure = .readFailed(error.localizedDescription)
                }
            }
        }
        if !sawBrowser { return .failure(.noBrowserFound) }
        return .failure(lastFailure ?? .noMatchingCookies(S.browserGeneric.s))
    }

    // MARK: - Keychain

    /// Chrome's Safe Storage item is ACL-restricted to Chrome, so a first read
    /// from another app needs the user to approve it. This is the legacy
    /// file-based keychain, where `SecKeychainSetUserInteractionAllowed` — not
    /// `kSecUseAuthenticationUI` — is what governs the prompt.

    private static func keychainPassphrase(_ browser: Browser) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deriveKey(_ passphrase: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = "saltysalt"
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passphrase, passphrase.utf8.count,
            salt, salt.utf8.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1_003,
            &key, key.count
        )
        return key
    }

    // MARK: - Profiles

    private static func profileDatabases(in root: URL) -> [(name: String, url: URL)] {
        let fm = FileManager.default
        let candidates = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        // "Default" first, then Profile 1, Profile 2, ... so the primary account wins.
        let names = candidates
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { lhs, rhs in
                if lhs == "Default" { return true }
                if rhs == "Default" { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        return names.compactMap { name in
            let db = root.appendingPathComponent(name).appendingPathComponent("Cookies")
            return fm.fileExists(atPath: db.path) ? (name, db) : nil
        }
    }

    // MARK: - SQLite

    private static func readCookies(at url: URL, key: [UInt8], domains: [String]) throws -> [String: String] {
        let jar = LocalSQLite.withReadOnlyCopy(of: url) { db in
            readCookies(db: db, key: key, domains: domains)
        }
        guard let jar else { throw ImportError.readFailed(S.databaseOpenFailed.s) }
        return jar
    }

    private static func readCookies(db: OpaquePointer, key: [UInt8], domains: [String]) -> [String: String] {
        // Chromium 24+ prepends a 32-byte SHA-256 of the host to the plaintext.
        // The schema version tells us definitively instead of guessing from bytes.
        let schemaVersion = LocalSQLite.integer(db, "SELECT value FROM meta WHERE key='version'") ?? 0
        let plaintextOffset = schemaVersion >= 24 ? 32 : 0

        let clause = domains.map { _ in "host_key LIKE ?" }.joined(separator: " OR ")
        var statement: OpaquePointer?
        let sql = "SELECT name, encrypted_value, value, expires_utc FROM cookies WHERE \(clause)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        for (index, domain) in domains.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), "%\(domain)", -1, LocalSQLite.transientText)
        }

        var jar: [String: String] = [:]
        let nowChromeEpoch = (Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePtr)

            let expires = sqlite3_column_double(statement, 3)
            if expires > 0, expires < nowChromeEpoch { continue }

            var value: String?
            if let blob = sqlite3_column_blob(statement, 1) {
                let count = Int(sqlite3_column_bytes(statement, 1))
                if count > 0 {
                    let encrypted = Data(bytes: blob, count: count)
                    value = decrypt(encrypted, key: key, plaintextOffset: plaintextOffset)
                }
            }
            if value == nil, let plainPtr = sqlite3_column_text(statement, 2) {
                let plain = String(cString: plainPtr)
                value = plain.isEmpty ? nil : plain
            }
            guard let value, !value.isEmpty else { continue }
            // Later rows are more specific hosts; first write wins to keep the
            // broadest (domain-level) session cookie.
            if jar[name] == nil { jar[name] = value }
        }
        return jar
    }

    // MARK: - Decryption

    static func decrypt(_ encrypted: Data, key: [UInt8], plaintextOffset: Int) -> String? {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else { return nil }
        let body = encrypted.dropFirst(3)
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }

        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)   // 16 spaces
        let status = body.withUnsafeBytes { raw -> CCCryptorStatus in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                key, key.count, iv,
                raw.baseAddress, body.count,
                &output, output.count, &moved
            )
        }
        guard status == kCCSuccess, moved > 0 else { return nil }

        var plain = Array(output.prefix(moved))
        // Strip PKCS#7 padding.
        if let pad = plain.last, pad > 0, Int(pad) <= kCCBlockSizeAES128, plain.count >= Int(pad) {
            plain.removeLast(Int(pad))
        }
        guard plain.count >= plaintextOffset else { return nil }
        return String(bytes: plain.dropFirst(plaintextOffset), encoding: .utf8)
    }

#if DEBUG
    static func testDeriveKey(_ passphrase: String) -> [UInt8] { deriveKey(passphrase) }

    /// Builds a blob in Chromium's exact on-disk shape so `decrypt` can be
    /// round-tripped without touching a real browser profile.
    static func testEncrypt(_ value: String, key: [UInt8], plaintextOffset: Int) -> Data {
        var plain = [UInt8](repeating: 0xAB, count: plaintextOffset)   // stand-in host hash
        plain.append(contentsOf: Array(value.utf8))
        let pad = kCCBlockSizeAES128 - (plain.count % kCCBlockSizeAES128)
        plain.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))

        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        _ = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
            key, key.count, iv,
            plain, plain.count,
            &output, output.count, &moved
        )
        return Data("v10".utf8) + Data(output.prefix(moved))
    }
#endif
}
