import Foundation

public enum MessageSender: String, Codable, Equatable, Sendable {
    case visitor
    case agent
    case unknown

    public init(from decoder: Decoder) throws {
        let value = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = MessageSender(rawValue: value) ?? .unknown
    }
}

public enum DeliveryState: String, Codable, Equatable, Sendable {
    case sent
    case sending
    case waiting   // queued, offline
    case failed

    public init(from decoder: Decoder) throws {
        let value = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = DeliveryState(rawValue: value) ?? .sent
    }
}

public struct Attachment: Codable, Equatable, Sendable {
    public var id: String?
    public var kind: String          // "image" or "file"
    public var url: String
    public var name: String
    public var mimeType: String
    public var size: Int?
    public var width: Int?
    public var height: Int?

    public init(id: String? = nil, kind: String, url: String, name: String, mimeType: String, size: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.kind = kind
        self.url = url
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
    }

    public var isImage: Bool { kind == "image" || mimeType.hasPrefix("image/") }

    private enum CodingKeys: String, CodingKey { case id, kind, url, name, mimeType, size, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        let mime = c.lenient(String.self, .mimeType) ?? ""
        mimeType = mime
        kind = c.lenient(String.self, .kind) ?? (mime.hasPrefix("image/") ? "image" : "file")
        url = c.lenient(String.self, .url) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        size = c.lenient(Int.self, .size)
        width = c.lenient(Int.self, .width)
        height = c.lenient(Int.self, .height)
    }
}

/// The page the customer is on. Sent with messages. Strings are at most 200 characters, `url` must be https.
public struct ChatContext: Codable, Equatable, Sendable {
    public var screen: String?
    public var itemType: String?
    public var itemId: String?
    public var itemTitle: String?
    public var url: String?

    public init(screen: String? = nil, itemType: String? = nil, itemId: String? = nil, itemTitle: String? = nil, url: String? = nil) {
        self.screen = screen
        self.itemType = itemType
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.url = url
    }

    public var isEmpty: Bool { screen == nil && itemType == nil && itemId == nil && itemTitle == nil && url == nil }

    /// Trims every string to 200 UTF-16 units and drops a url that does not start with lowercase https://. Nil when nothing is left.
    public func sanitized() -> ChatContext? {
        func clip(_ value: String?) -> String? {
            guard let value = value, !value.isEmpty else { return nil }
            return value.clipped(toUTF16: 200)
        }
        var safeURL = clip(url)
        if let candidate = safeURL, !candidate.hasPrefix("https://") { safeURL = nil }
        let result = ChatContext(screen: clip(screen), itemType: clip(itemType), itemId: clip(itemId), itemTitle: clip(itemTitle), url: safeURL)
        return result.isEmpty ? nil : result
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public var serverId: String?
    public var clientMessageId: String?
    public var from: MessageSender
    public var text: String
    public var attachments: [Attachment]
    public var createdAt: String
    public var agentName: String?
    public var agentAvatarUrl: String?
    public var delivery: DeliveryState
    public var failureReason: String?

    public init(serverId: String? = nil, clientMessageId: String? = nil, from: MessageSender, text: String, attachments: [Attachment] = [],
                createdAt: String, agentName: String? = nil, agentAvatarUrl: String? = nil, delivery: DeliveryState = .sent, failureReason: String? = nil) {
        self.serverId = serverId
        self.clientMessageId = clientMessageId
        self.from = from
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.agentName = agentName
        self.agentAvatarUrl = agentAvatarUrl
        self.delivery = delivery
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case serverId = "id"
        case clientMessageId, from, text, attachments, createdAt, agentName, agentAvatarUrl, delivery, failureReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = c.lenient(String.self, .serverId)
        clientMessageId = c.lenient(String.self, .clientMessageId)
        from = c.lenient(MessageSender.self, .from) ?? .unknown
        text = c.lenient(String.self, .text) ?? ""
        attachments = c.lenient(LossyArray<Attachment>.self, .attachments)?.items ?? []
        createdAt = c.lenient(String.self, .createdAt) ?? ""
        agentName = c.lenient(String.self, .agentName)
        agentAvatarUrl = c.lenient(String.self, .agentAvatarUrl)
        delivery = c.lenient(DeliveryState.self, .delivery) ?? .sent
        failureReason = c.lenient(String.self, .failureReason)
    }

    /// Stable for the whole life of a message: the same value before and after the server confirms it.
    public var stableId: String { clientMessageId ?? serverId ?? createdAt }
    public var id: String { stableId }
    public var date: Date { ISODate.parse(createdAt) ?? Date(timeIntervalSince1970: 0) }
    public var isUsable: Bool { from != .unknown && (serverId != nil || clientMessageId != nil) }
}

public struct MessagesPage: Equatable, Sendable {
    public var conversationId: String?
    public var messages: [ChatMessage]
    public var nextBefore: String?
    public var latest: String?

    public init(conversationId: String? = nil, messages: [ChatMessage] = [], nextBefore: String? = nil, latest: String? = nil) {
        self.conversationId = conversationId
        self.messages = messages
        self.nextBefore = nextBefore
        self.latest = latest
    }
}

extension MessagesPage: Decodable {
    private enum CodingKeys: String, CodingKey { case conversationId, messages, nextBefore, latest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = c.lenient(String.self, .conversationId)
        // Unknown `from` and items without an id are skipped.
        messages = (c.lenient(LossyArray<ChatMessage>.self, .messages)?.items ?? []).filter { $0.isUsable }
        nextBefore = c.lenient(String.self, .nextBefore)
        latest = c.lenient(String.self, .latest)
    }
}

public struct LastMessage: Codable, Equatable, Sendable {
    public var from: MessageSender
    public var text: String
    public var hasAttachment: Bool
    /// "image", "file" or nil. A value the SDK does not know is treated as a file.
    public var attachmentKind: String?

    public init(from: MessageSender, text: String, hasAttachment: Bool, attachmentKind: String? = nil) {
        self.from = from
        self.text = text
        self.hasAttachment = hasAttachment
        self.attachmentKind = attachmentKind
    }

    private enum CodingKeys: String, CodingKey { case from, text, hasAttachment, attachmentKind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = c.lenient(MessageSender.self, .from) ?? .unknown
        text = c.lenient(String.self, .text) ?? ""
        hasAttachment = c.lenient(Bool.self, .hasAttachment) ?? false
        attachmentKind = c.lenient(String.self, .attachmentKind)
    }
}

public struct ConversationSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var lastMessageAt: String?
    public var lastMessage: LastMessage?
    public var agentName: String?
    public var agentAvatarUrl: String?
    public var unread: Int

    public init(id: String, status: String = "open", lastMessageAt: String? = nil, lastMessage: LastMessage? = nil, agentName: String? = nil, agentAvatarUrl: String? = nil, unread: Int = 0) {
        self.id = id
        self.status = status
        self.lastMessageAt = lastMessageAt
        self.lastMessage = lastMessage
        self.agentName = agentName
        self.agentAvatarUrl = agentAvatarUrl
        self.unread = unread
    }

    private enum CodingKeys: String, CodingKey { case id, status, lastMessageAt, lastMessage, agentName, agentAvatarUrl, unread }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenient(String.self, .id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, DecodingError.Context(codingPath: [], debugDescription: "id"))
        }
        self.id = id
        status = c.lenient(String.self, .status) ?? "open"
        lastMessageAt = c.lenient(String.self, .lastMessageAt)
        lastMessage = c.lenient(LastMessage.self, .lastMessage)
        agentName = c.lenient(String.self, .agentName)
        agentAvatarUrl = c.lenient(String.self, .agentAvatarUrl)
        unread = c.lenient(Int.self, .unread) ?? 0
    }

    public var lastDate: Date? { lastMessageAt.flatMap { ISODate.parse($0) } }
}

public struct ConversationsPage: Codable, Equatable, Sendable {
    public var conversations: [ConversationSummary]
    public var nextCursor: String?
    public var unreadTotal: Int

    public init(conversations: [ConversationSummary] = [], nextCursor: String? = nil, unreadTotal: Int = 0) {
        self.conversations = conversations
        self.nextCursor = nextCursor
        self.unreadTotal = unreadTotal
    }

    private enum CodingKeys: String, CodingKey { case conversations, nextCursor, unreadTotal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = c.lenient(LossyArray<ConversationSummary>.self, .conversations)?.items ?? []
        nextCursor = c.lenient(String.self, .nextCursor)
        unreadTotal = c.lenient(Int.self, .unreadTotal) ?? 0
    }
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public var sessionToken: String
    public var expiresAt: String?
    public var identified: Bool
    public var customerName: String?
    public var versionId: String?

    public init(sessionToken: String, expiresAt: String? = nil, identified: Bool = false, customerName: String? = nil, versionId: String? = nil) {
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.identified = identified
        self.customerName = customerName
        self.versionId = versionId
    }

    private enum CodingKeys: String, CodingKey { case sessionToken, expiresAt, customer, versionId }
    private enum CustomerKeys: String, CodingKey { case identified, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let token = c.lenient(String.self, .sessionToken), !token.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.sessionToken, DecodingError.Context(codingPath: [], debugDescription: "sessionToken"))
        }
        sessionToken = token
        expiresAt = c.lenient(String.self, .expiresAt)
        versionId = c.lenient(String.self, .versionId)
        if let customer = try? c.nestedContainer(keyedBy: CustomerKeys.self, forKey: .customer) {
            identified = customer.lenient(Bool.self, .identified) ?? false
            customerName = customer.lenient(String.self, .name)
        } else {
            identified = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionToken, forKey: .sessionToken)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(versionId, forKey: .versionId)
        var customer = c.nestedContainer(keyedBy: CustomerKeys.self, forKey: .customer)
        try customer.encode(identified, forKey: .identified)
        try customer.encodeIfPresent(customerName, forKey: .name)
    }
}

public struct SendReceipt: Decodable, Equatable, Sendable {
    public var clientMessageId: String?
    public var accepted: Bool
    public var conversationId: String?

    private enum CodingKeys: String, CodingKey { case clientMessageId, accepted, conversationId }

    public init(clientMessageId: String?, accepted: Bool, conversationId: String?) {
        self.clientMessageId = clientMessageId
        self.accepted = accepted
        self.conversationId = conversationId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientMessageId = c.lenient(String.self, .clientMessageId)
        accepted = c.lenient(Bool.self, .accepted) ?? true
        conversationId = c.lenient(String.self, .conversationId)
    }
}

/// One event from the SSE stream.
public enum RealtimeEvent: Equatable, Sendable {
    case ready(conversationId: String?)
    case message(ChatMessage, conversationId: String?)
    case typing(active: Bool, agentName: String?)
    case agentJoined(agentName: String?, avatarUrl: String?)
    case unread(Int)
}

public enum RealtimeEventDecoder {
    /// Nil for an unknown event name or bad data. Never throws.
    public static func decode(_ event: SSEEvent) -> RealtimeEvent? {
        guard let name = event.name, let data = event.data.data(using: .utf8) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch name {
        case "ready":
            return .ready(conversationId: object["conversationId"] as? String)
        case "message":
            guard let message = try? JSONDecoder().decode(ChatMessage.self, from: data), message.isUsable else { return nil }
            return .message(message, conversationId: object["conversationId"] as? String)
        case "typing":
            return .typing(active: (object["active"] as? Bool) ?? false, agentName: object["agentName"] as? String)
        case "agent_joined":
            return .agentJoined(agentName: object["agentName"] as? String, avatarUrl: object["agentAvatarUrl"] as? String)
        case "unread":
            guard let total = object["unreadTotal"] as? Int else { return nil }
            return .unread(total)
        default:
            return nil
        }
    }
}

extension String {
    /// The longest start of the string that fits in `limit` UTF-16 units (the server counts these). Never cuts a character in two.
    func clipped(toUTF16 limit: Int) -> String {
        guard limit > 0 else { return "" }
        if utf16.count <= limit { return self }
        var used = 0
        var result = ""
        for character in self {
            let size = character.utf16.count
            if used + size > limit { break }
            used += size
            result.append(character)
        }
        return result
    }
}
