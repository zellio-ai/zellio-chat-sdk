import Foundation

/// The messages of one conversation, oldest first, plus the cursors. Merges by `clientMessageId`.
public struct Timeline: Codable, Equatable, Sendable {
    public static let maxStored = 200

    public var messages: [ChatMessage]
    public var nextBefore: String?
    public var latest: String?

    public init(messages: [ChatMessage] = [], nextBefore: String? = nil, latest: String? = nil) {
        self.messages = messages
        self.nextBefore = nextBefore
        self.latest = latest
    }

    public var hasOlder: Bool { nextBefore != nil }

    /// Adds or replaces one message. Returns true when the list changed.
    ///
    /// A server message with the same `clientMessageId` replaces the local one in place, so the row keeps its
    /// position and its `stableId`: no scroll jump and no flash. Otherwise a message with the same server id is
    /// replaced in place. A new message goes in by time, after the last message with the same or an earlier time.
    @discardableResult
    public mutating func upsert(_ message: ChatMessage) -> Bool {
        if let cid = message.clientMessageId, let index = messages.firstIndex(where: { $0.clientMessageId == cid }) {
            return replace(at: index, with: message)
        }
        if let sid = message.serverId, let index = messages.firstIndex(where: { $0.serverId == sid }) {
            return replace(at: index, with: message)
        }
        let date = message.date
        var position = 0
        var index = messages.count - 1
        while index >= 0 {
            if messages[index].date <= date { position = index + 1; break }
            index -= 1
        }
        messages.insert(message, at: position)
        return true
    }

    private mutating func replace(at index: Int, with message: ChatMessage) -> Bool {
        var next = message
        // A server copy never goes back to a local state, and keeps the local identity.
        if next.clientMessageId == nil { next.clientMessageId = messages[index].clientMessageId }
        if next == messages[index] { return false }
        messages[index] = next
        return true
    }

    /// Applies a page from the server. `older` pages move the `nextBefore` cursor; newer pages move `latest`.
    public mutating func apply(page: MessagesPage, older: Bool, initial: Bool = false) {
        for message in page.messages { upsert(message) }
        if older || initial { nextBefore = page.nextBefore }
        if !older, let latest = page.latest { self.latest = latest }
        if initial, let latest = page.latest { self.latest = latest }
    }

    public mutating func setDelivery(clientMessageId: String, _ delivery: DeliveryState, reason: String? = nil) {
        guard let index = messages.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return }
        guard messages[index].serverId == nil else { return }
        messages[index].delivery = delivery
        messages[index].failureReason = reason
    }

    /// Keeps the newest `limit` messages. Cuts the older cursor off when anything was dropped, so paging stays honest.
    public mutating func trim(limit: Int = Timeline.maxStored) {
        guard messages.count > limit else { return }
        messages.removeFirst(messages.count - limit)
    }

    /// What is saved to disk: server-confirmed messages only, newest 200. Queued messages live in the queue.
    public func persisted() -> Timeline {
        var copy = self
        copy.messages = messages.filter { $0.serverId != nil }
        copy.trim()
        return copy
    }
}

public enum ThreadRow: Equatable, Sendable, Identifiable {
    case date(key: String, label: String)
    case message(MessageRow)
    case typing(agentName: String?)

    public var id: String {
        switch self {
        case .date(let key, _): return "date-" + key
        case .message(let row): return "msg-" + row.message.stableId
        case .typing: return "typing"
        }
    }
}

public struct MessageRow: Equatable, Sendable {
    public var message: ChatMessage
    /// First message of a group: the larger gap above it.
    public var startsGroup: Bool
    /// Last message of a group: it has the tail and the avatar.
    public var endsGroup: Bool
    /// The agent name shows above the first agent message of a group.
    public var showsName: Bool
    /// The delivery line shows under the newest visitor message only. Failed messages always show theirs.
    public var showsDelivery: Bool
    public var timeLabel: String
}

public enum ThreadLayout {
    /// Builds the rows: date separators, grouping within 5 minutes by the same sender, delivery lines.
    public static func rows(messages: [ChatMessage], typing: Bool, typingName: String?, now: Date, locale: ChatLocale, timeZone: TimeZone = .current) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let newestVisitor = messages.lastIndex { $0.from == .visitor }
        var previous: ChatMessage?
        for (index, message) in messages.enumerated() {
            let date = message.date
            let newDay = previous.map { !calendar.isDate($0.date, inSameDayAs: date) } ?? true
            if newDay {
                let comps = calendar.dateComponents([.year, .month, .day], from: date)
                let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
                rows.append(.date(key: key, label: ChatFormat.daySeparator(date, now: now, locale: locale, timeZone: timeZone)))
            }
            let sameGroupAsPrevious = !newDay && previous.map { isSameGroup($0, message) } ?? false
            var endsGroup = true
            if index + 1 < messages.count {
                let next = messages[index + 1]
                endsGroup = !(calendar.isDate(next.date, inSameDayAs: date) && isSameGroup(message, next))
            }
            let showsName = message.from == .agent && !sameGroupAsPrevious && !(message.agentName ?? "").isEmpty
            let showsDelivery = message.from == .visitor && (index == newestVisitor || message.delivery == .failed)
            rows.append(.message(MessageRow(message: message, startsGroup: !sameGroupAsPrevious, endsGroup: endsGroup,
                                            showsName: showsName, showsDelivery: showsDelivery,
                                            timeLabel: ChatFormat.time(date, locale: locale, timeZone: timeZone))))
            previous = message
        }
        if typing { rows.append(.typing(agentName: typingName)) }
        return rows
    }

    public static func isSameGroup(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        guard a.from == b.from else { return false }
        if a.from == .agent && a.agentName != b.agentName && a.agentName != nil && b.agentName != nil { return false }
        return abs(b.date.timeIntervalSince(a.date)) <= Metrics.groupWindowSeconds
    }

    /// The delivery text under a visitor message. Nil when nothing shows.
    public static func deliveryText(_ message: ChatMessage, strings: ChatStrings) -> String? {
        switch message.delivery {
        case .sending: return strings.string("delivery.sending")
        case .waiting: return strings.string("delivery.waiting")
        case .failed: return strings.string("delivery.failed")
        case .sent: return strings.string("delivery.sent")
        }
    }
}
