import Foundation

public enum UILanguage: Equatable {
    case ja, en, zh, ko, es

    /// Picks the first supported language from the preferred list; unsupported ones fall back to English.
    public static func resolve(preferred: [String]) -> UILanguage {
        for id in preferred {
            let code = id.lowercased()
            if code.hasPrefix("ja") { return .ja }
            if code.hasPrefix("en") { return .en }
            if code.hasPrefix("zh") { return .zh }
            if code.hasPrefix("ko") { return .ko }
            if code.hasPrefix("es") { return .es }
        }
        return .en
    }
}
