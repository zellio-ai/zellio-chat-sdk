import Foundation

public struct ZellioPush: Equatable, Sendable {
    public var version: Int
    public var type: String
    public var conversationId: String?
    public var messageId: String?
}

public enum PushPayload {
    public static let key = "zellio"

    /// True only when the payload has the `zellio` key.
    public static func isZellioPush(_ payload: [AnyHashable: Any]) -> Bool {
        payload[key] != nil
    }

    /// Reads the `zellio` value. It is an object on APNs and a JSON string on FCM. Both work.
    public static func parse(_ payload: [AnyHashable: Any]) -> ZellioPush? {
        guard let raw = payload[key] else { return nil }
        var object: [String: Any]?
        if let dictionary = raw as? [String: Any] {
            object = dictionary
        } else if let dictionary = raw as? [AnyHashable: Any] {
            var converted: [String: Any] = [:]
            for (k, v) in dictionary { if let name = k as? String { converted[name] = v } }
            object = converted
        } else if let text = raw as? String, let data = text.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let fields = object else { return nil }
        let version = (fields["v"] as? Int) ?? Int((fields["v"] as? String) ?? "") ?? 1
        return ZellioPush(version: version, type: (fields["type"] as? String) ?? "message",
                          conversationId: fields["conversationId"] as? String, messageId: fields["messageId"] as? String)
    }
}

/// The unread number. Safe from any thread.
public final class UnreadTracker: @unchecked Sendable {
    private struct State {
        var count = 0
        var listeners: [Int: @Sendable (Int) -> Void] = [:]
        var nextToken = 0
    }
    private let state = Locked(State())

    public init() {}

    public var count: Int { state.with { $0.count } }

    public func set(_ value: Int) {
        let clean = max(0, value)
        let (changed, listeners): (Bool, [@Sendable (Int) -> Void]) = state.with { s in
            let changed = s.count != clean
            s.count = clean
            return (changed, Array(s.listeners.values))
        }
        if changed { for listener in listeners { listener(clean) } }
    }

    /// Returns a token for `remove`. The listener is also called once with the current value.
    @discardableResult
    public func add(_ listener: @escaping @Sendable (Int) -> Void) -> Int {
        let (token, current): (Int, Int) = state.with { s in
            s.nextToken += 1
            s.listeners[s.nextToken] = listener
            return (s.nextToken, s.count)
        }
        listener(current)
        return token
    }

    public func remove(_ token: Int) { state.with { $0.listeners[token] = nil } }
}
