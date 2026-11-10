import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Looks up SDK strings. The table is generated from sdks/design/strings.json.
public struct ChatStrings: Sendable {
    public let locale: ChatLocale

    public init(locale: ChatLocale) { self.locale = locale }

    public func string(_ key: String) -> String {
        let table = locale == .ar ? ChatStringTable.ar : ChatStringTable.en
        return table[key] ?? ChatStringTable.en[key] ?? key
    }

    public static var keys: Set<String> { Set(ChatStringTable.en.keys) }
    public static var arabicKeys: Set<String> { Set(ChatStringTable.ar.keys) }

    /// "{sender}, {text}, {time}, {delivery}" for VoiceOver. Empty parts are left out.
    public func accessibilitySummary(sender: String, text: String, time: String, delivery: String?) -> String {
        let separator = locale == .ar ? "، " : ", "
        return [sender, text, time, delivery ?? ""].filter { !$0.isEmpty }.joined(separator: separator)
    }
}

public enum ChatFormat {
    /// Latin digits in both languages, like the web widget.
    public static func formatter(_ locale: ChatLocale) -> Locale {
        Locale(identifier: locale == .ar ? "ar@numbers=latn" : "en_US_POSIX")
    }

    public static func time(_ date: Date, locale: ChatLocale, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = formatter(locale)
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    public static func day(_ date: Date, locale: ChatLocale, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = formatter(locale)
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// "Today", "Yesterday", or a date.
    public static func daySeparator(_ date: Date, now: Date, locale: ChatLocale, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let strings = ChatStrings(locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return strings.string("thread.today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return strings.string("thread.yesterday")
        }
        return day(date, locale: locale, timeZone: timeZone)
    }

    /// Conversation list time: the time today, "Yesterday", or a date.
    public static func listTime(_ date: Date, now: Date, locale: ChatLocale, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return time(date, locale: locale, timeZone: timeZone) }
        return daySeparator(date, now: now, locale: locale, timeZone: timeZone)
    }

    public static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
}

/// Which language the chat shows.
public enum LocaleChoice {
    /// Order: the code option, then the snapshot language policy.
    /// `option` nil means follow the device.
    public static func choose(option: ChatLocale?, policy: LanguagePolicy?, deviceLanguageCode: String?) -> ChatLocale {
        let device = deviceLocale(deviceLanguageCode)
        if let option = option { return option }
        if let policy = policy {
            if case .single(let locale) = policy { return locale }
            if case .both(let defaultLocale, let startIn) = policy {
                switch startIn {
                case "ar": return .ar
                case "en": return .en
                default: return device ?? defaultLocale
                }
            }
        }
        return device ?? .en
    }

    /// `ar` or `en` only. Accepts "ar-EG", "ar_EG", "EN".
    public static func deviceLocale(_ code: String?) -> ChatLocale? {
        guard let code = code?.lowercased() else { return nil }
        let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return ChatLocale(rawValue: language)
    }
}
