import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SDK constants.
public enum SDKInfo {
    public static let version = "1.0.0"
    public static let platform = "ios"
    public static let defaultBaseURL = "https://app.zellio.ai"
    public static let apiPath = "/api/v1/zeechat/mobile"
}

/// A small lock around a value. Used where an actor would be too heavy.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    public var snapshot: Value { with { $0 } }
}

/// Time and sleeping, injectable so tests never wait.
public protocol ChatClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: ChatClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        if seconds <= 0 { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
    }
}

/// Random source, injectable for jitter tests.
public protocol RandomSource: Sendable {
    /// A value in 0..<1.
    func unit() -> Double
}

public struct SystemRandom: RandomSource {
    public init() {}
    public func unit() -> Double { Double.random(in: 0..<1) }
}

public enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let lock = NSLock()

    public static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    public static func string(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.string(from: date)
    }
}

public enum SemVer {
    /// Compares dotted numeric versions. Missing parts count as 0. Returns -1, 0 or 1.
    public static func compare(_ a: String, _ b: String) -> Int {
        let left = parts(a)
        let right = parts(b)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ text: String) -> [Int] {
        let core = text.split(separator: "-").first.map(String.init) ?? text
        return core.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
    }
}

/// Decodes a JSON value of any shape without keeping it. Used to step over a bad array element.
struct SkipValue: Decodable {
    init(from decoder: Decoder) throws {}
}

/// An array that skips elements that do not decode.
struct LossyArray<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                result.append(item)
            } else {
                _ = try? container.decode(SkipValue.self)
            }
        }
        items = result
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, or nil when the key is missing or has the wrong type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let value = try? decodeIfPresent(type, forKey: key) else { return nil }
        return value
    }
}

enum JSON {
    static func decoder() -> JSONDecoder { JSONDecoder() }
    static func encoder() -> JSONEncoder { JSONEncoder() }
}
