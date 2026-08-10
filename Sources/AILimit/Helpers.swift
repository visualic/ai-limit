import Foundation

enum Keys {
    static let refreshInterval = "refreshInterval"
    static let showPercent = "showPercent"
    static let qwenRegion = "qwenRegion"
    static let qwenCookie = "qwen-cookie"
    static let qwenCookieSource = "qwenCookieSource"
    static let language = "language"
    /// Last successful browser import, kept in our own Keychain item so a later
    /// denied read of the browser's item does not take the app offline.
    static let qwenCookieAuto = "qwen-cookie-auto"
    static let cursorCookieAuto = "cursor-cookie-auto"
    /// Which provider's number the menu bar shows; "" means the highest value.
    static let menuBarProvider = "menuBarProvider"
    /// Services the user switched off. See `ProviderVisibility`.
    static let disabledProviders = "disabledProviders"
}

enum CookieExtract {
    /// Accepts either a raw Cookie header value or a pasted `curl` command,
    /// and returns the cookie header string.
    static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().contains("curl") {
            return extractFromCurl(trimmed)
        }
        return trimmed
    }

    static func extractFromCurl(_ text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\\\n", with: " ")
        let patterns = [
            #"-H\s+\$?'cookie:\s*([^']*)'"#,
            #"-H\s+\$?\"cookie:\s*([^\"]*)\""#,
        ]
        let range = NSRange(normalized.startIndex..., in: normalized)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: normalized, options: [], range: range),
                  match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: normalized) else { continue }
            let value = String(normalized[groupRange]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

extension URLResponse {
    var httpStatus: Int { (self as? HTTPURLResponse)?.statusCode ?? -1 }
}

func num(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String, let parsed = Double(string) { return parsed }
    return nil
}

enum DateParse {
    private static let plainFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]

    static func parse(_ value: Any?) -> Date? {
        if let epoch = num(value), epoch > 0 {
            // Epochs are reported in seconds or milliseconds depending on the API.
            return Date(timeIntervalSince1970: epoch >= 1e12 ? epoch / 1000 : epoch)
        }
        guard let string = value as? String else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in plainFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

enum NumberFormat {
    /// `20_000_000` → `20M`, `1_250_000` → `1.25M`, `10_000` → `10,000`.
    /// Values below 100K stay spelled out — Qwen's real plan quotas are in the
    /// hundreds-to-tens-of-thousands, where `10K` reads worse than `10,000`.
    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude < 100_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = ","
            formatter.groupingSize = 3
            formatter.maximumFractionDigits = value == value.rounded() ? 0 : 2
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
        }
        let (scaled, suffix): (Double, String)
        switch magnitude {
        case 1e9...: (scaled, suffix) = (value / 1e9, "B")
        case 1e6...: (scaled, suffix) = (value / 1e6, "M")
        case 1e3...: (scaled, suffix) = (value / 1e3, "K")
        default: (scaled, suffix) = (value, "")
        }
        let rounded = (scaled * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.2f", rounded)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression) + suffix
    }
}

enum RelativeTime {
    /// `Text(date, style: .relative)` renders as `2 days, 23 hr`, which reads badly
    /// next to Korean copy and cannot be localized. The popover re-fetches on
    /// open, so a static string is fine.
    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return S.resetsSoon.s }
        if seconds >= 7 * 86_400 {
            return S.resetsOn(date.formatted(.dateTime.month().day()))
        }
        let total = Int(seconds)
        return S.resetsIn(days: total / 86_400,
                          hours: (total % 86_400) / 3_600,
                          minutes: (total % 3_600) / 60)
    }
}

enum JSONWalk {
    static func expandEmbedded(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, sub) in dict { out[key] = expandEmbedded(sub) }
            return out
        }
        if let array = value as? [Any] {
            return array.map(expandEmbedded)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikeJSON = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
                || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            if looksLikeJSON,
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return expandEmbedded(parsed)
            }
        }
        return value
    }

    static func findObject(in value: Any, containing keys: [String]) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for (_, sub) in dict {
                if let found = findObject(in: sub, containing: keys) { return found }
            }
        }
        if let array = value as? [Any] {
            for sub in array {
                if let found = findObject(in: sub, containing: keys) { return found }
            }
        }
        return nil
    }

    /// Searches one key at a time so caller-declared priority survives the whole
    /// tree: a low-priority key nested shallowly must not beat a high-priority
    /// key nested deeper. Key matching is case-insensitive.
    static func findFirst<T>(forKeys keys: [String], in value: Any, transform: (Any) -> T?) -> T? {
        for key in keys {
            if let found = findFirst(forKey: key, in: value, transform: transform) { return found }
        }
        return nil
    }

    private static func findFirst<T>(forKey key: String, in value: Any, transform: (Any) -> T?) -> T? {
        if let dict = value as? [String: Any] {
            for (candidate, sub) in dict where candidate.caseInsensitiveCompare(key) == .orderedSame {
                if let converted = transform(sub) { return converted }
            }
            for (_, sub) in dict {
                if let found = findFirst(forKey: key, in: sub, transform: transform) { return found }
            }
        }
        if let array = value as? [Any] {
            for sub in array {
                if let found = findFirst(forKey: key, in: sub, transform: transform) { return found }
            }
        }
        return nil
    }

    static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        findFirst(forKeys: keys, in: value) { raw in
            guard let string = raw as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func findFirstValue(forKeys keys: [String], in value: Any) -> Any? {
        findFirst(forKeys: keys, in: value) { $0 }
    }

    /// Every dictionary anywhere in the tree that maps one of `keys` to `false`.
    /// Used to catch a nested `{"success": false}` frame inside an outer `200` envelope.
    static func objectsFailing(keys: [String], in value: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = value as? [String: Any] {
            if keys.contains(where: { (dict[$0] as? NSNumber)?.boolValue == false }) {
                found.append(dict)
            }
            for (_, sub) in dict { found.append(contentsOf: objectsFailing(keys: keys, in: sub)) }
        }
        if let array = value as? [Any] {
            for sub in array { found.append(contentsOf: objectsFailing(keys: keys, in: sub)) }
        }
        return found
    }
}

enum FormEncoding {
    static func encode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}
