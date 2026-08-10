import Foundation
import Security

enum Keychain {
    static let service = "com.visualic.ai-limit"

    /// Legacy (file-based) Keychain items carry a per-application ACL. Reading one
    /// from a binary the ACL does not list makes securityd raise an approval
    /// dialog and park the caller in a synchronous Mach round trip until the user
    /// answers — and in an LSUIElement app that dialog is easy to miss entirely.
    /// Every background read therefore runs with interaction switched off so it
    /// fails fast instead of hanging; only explicit user actions may prompt.
    ///
    /// `kSecUseAuthenticationUI` does not govern this: measured, it still takes
    /// the full securityd round trip. `SecKeychainSetUserInteractionAllowed` is
    /// the only working lever, and is resolved at runtime because the imported
    /// declaration is deprecated and would warn at every call site.
    private static let setInteractionAllowed: (@convention(c) (DarwinBoolean) -> OSStatus)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (DarwinBoolean) -> OSStatus).self)
    }()

    /// Serializes the process-global interaction flag so a background read cannot
    /// re-enable prompting midway through another read.
    private static let interactionLock = NSLock()

    static func withInteraction<T>(_ allowed: Bool, _ body: () -> T) -> T {
        interactionLock.lock()
        defer {
            _ = setInteractionAllowed?(DarwinBoolean(true))
            interactionLock.unlock()
        }
        _ = setInteractionAllowed?(DarwinBoolean(allowed))
        return body()
    }

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    /// - Parameter allowInteraction: pass true only from an explicit user action.
    static func load(_ account: String, allowInteraction: Bool = false) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return withInteraction(allowInteraction) {
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Keychain {
    /// Runs a blocking Keychain read off the Swift concurrency cooperative pool
    /// with a hard deadline.
    ///
    /// Even an interactive read must be bounded: if the user never answers the
    /// approval dialog (easy to miss from an LSUIElement app), a bare
    /// `SecItemCopyMatching` parks forever and takes the refresh down with it.
    /// Measured: a release-signed build waiting on that dialog did not return
    /// after 140s.
    static func bounded<T: Sendable>(
        timeout: TimeInterval,
        _ body: @escaping @Sendable () -> T?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            nonisolated(unsafe) var resumed = false
            @Sendable func finish(_ value: T?) {
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                if !already { continuation.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
            DispatchQueue.global(qos: .userInitiated).async { finish(body()) }
        }
    }

    static func loadAsync(
        _ account: String,
        allowInteraction: Bool = false,
        timeout: TimeInterval = 20
    ) async -> String? {
        await bounded(timeout: timeout) { load(account, allowInteraction: allowInteraction) }
    }
}
