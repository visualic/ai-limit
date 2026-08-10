import Foundation
import SQLite3

/// Reads the session Cursor.app already holds, instead of going through the
/// browser.
///
/// Cursor is an Electron app and keeps its credentials in a plain, unencrypted
/// SQLite database in its own Application Support folder. That makes it a much
/// better source than browser cookies: no Keychain approval, no dependency on
/// which browser the user prefers, and it works even when they have never signed
/// in to cursor.com in a browser at all.
///
/// The web API does not accept the raw token as a bearer — it expects the WorkOS
/// session cookie, which is `{sub}::{jwt}` where `sub` is the subject claim of
/// that same token. Verified against the live API.
enum CursorLocalAuth {

    struct Session {
        let cookieHeader: String
        /// `stripeMembershipType`, available without any network call.
        let membershipType: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    static var stateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: stateDatabaseURL.path)
    }

    static func session() -> Session? {
        guard let values = readItems(keys: [
            "cursorAuth/accessToken",
            "cursorAuth/stripeMembershipType",
        ]) else { return nil }

        guard let token = values["cursorAuth/accessToken"], !token.isEmpty,
              let subject = jwtClaim(token, "sub") as? String, !subject.isEmpty else {
            return nil
        }
        let expiry = (jwtClaim(token, "exp") as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return Session(
            cookieHeader: "WorkosCursorSessionToken=\(subject)::\(token)",
            membershipType: values["cursorAuth/stripeMembershipType"],
            expiresAt: expiry
        )
    }

    // MARK: - Internals

    private static func readItems(keys: [String]) -> [String: String]? {
        let found = LocalSQLite.withReadOnlyCopy(of: stateDatabaseURL) { db -> [String: String] in
            var values: [String: String] = [:]
            for key in keys {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?",
                                         -1, &statement, nil) == SQLITE_OK,
                      let statement else { continue }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, key, -1, LocalSQLite.transientText)
                if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                    values[key] = String(cString: text)
                }
            }
            return values
        }
        return (found?.isEmpty ?? true) ? nil : found
    }

    /// Minimal JWT payload read — the token is only inspected, never verified;
    /// the server is the one that validates it.
    static func jwtClaim(_ token: String, _ name: String) -> Any? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return payload[name]
    }
}
