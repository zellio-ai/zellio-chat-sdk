import Foundation

public enum QueueStatus: String, Codable, Equatable, Sendable { case pending, failed }

public struct QueuedMessage: Codable, Equatable, Sendable {
    public var clientMessageId: String
    public var text: String
    public var attachments: [Attachment]
    public var context: ChatContext?
    public var createdAt: Date
    public var sequence: Int
    public var attempts: Int
    public var status: QueueStatus
    public var failureReason: String?
    public var conversationId: String?

    public var attachmentIds: [String] { attachments.compactMap { $0.id } }

    public func asMessage(delivery: DeliveryState) -> ChatMessage {
        ChatMessage(serverId: nil, clientMessageId: clientMessageId, from: .visitor, text: text, attachments: attachments,
                    createdAt: ISODate.string(createdAt), delivery: delivery, failureReason: failureReason)
    }
}

/// The saved send queue. Order is the order the customer tapped send. Survives restarts.
public final class OfflineQueue: @unchecked Sendable {
    public static let expiry: TimeInterval = 24 * 60 * 60

    private let storage: StorageBackend
    private let clock: ChatClock
    private let lock = NSLock()
    private var items: [QueuedMessage]

    public init(storage: StorageBackend, clock: ChatClock = SystemClock()) {
        self.storage = storage
        self.clock = clock
        self.items = storage.load([QueuedMessage].self, StorageName.queue) ?? []
    }

    private func persist() { storage.save(items, StorageName.queue) }

    public var all: [QueuedMessage] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.sequence < $1.sequence } }
    public var pending: [QueuedMessage] { all.filter { $0.status == .pending } }

    @discardableResult
    public func enqueue(clientMessageId: String = UUID().uuidString.lowercased(), text: String, attachments: [Attachment] = [], context: ChatContext?, conversationId: String?) -> QueuedMessage {
        lock.lock(); defer { lock.unlock() }
        let next = (items.map { $0.sequence }.max() ?? 0) + 1
        let item = QueuedMessage(clientMessageId: clientMessageId, text: text, attachments: attachments, context: context,
                                 createdAt: clock.now(), sequence: next, attempts: 0, status: .pending, failureReason: nil, conversationId: conversationId)
        items.append(item)
        persist()
        return item
    }

    public func item(_ clientMessageId: String) -> QueuedMessage? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.clientMessageId == clientMessageId }
    }

    public func remove(_ clientMessageId: String) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.clientMessageId == clientMessageId }
        persist()
    }

    public func recordAttempt(_ clientMessageId: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.clientMessageId == clientMessageId }) {
            items[index].attempts += 1
            persist()
        }
    }

    public func markFailed(_ clientMessageId: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.clientMessageId == clientMessageId }) {
            items[index].status = .failed
            items[index].failureReason = reason
            persist()
        }
    }

    /// "Try again": back to pending in the same place. The 24 hours start again.
    public func retry(_ clientMessageId: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.clientMessageId == clientMessageId }) {
            items[index].status = .pending
            items[index].failureReason = nil
            items[index].attempts = 0
            items[index].createdAt = clock.now()
            persist()
        }
    }

    /// Marks pending messages older than 24 hours as failed. Returns their ids.
    @discardableResult
    public func expireOld() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        var expired: [String] = []
        for index in items.indices where items[index].status == .pending && now.timeIntervalSince(items[index].createdAt) >= OfflineQueue.expiry {
            items[index].status = .failed
            items[index].failureReason = "expired"
            expired.append(items[index].clientMessageId)
        }
        if !expired.isEmpty { persist() }
        return expired
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items = []
        storage.remove(StorageName.queue)
    }
}

public enum SendOutcome: Equatable, Sendable {
    case sent(SendReceipt)
    case retryLater(after: TimeInterval?)
    case failedPermanently(reason: String)
}

public enum OutboxPolicy {
    /// 401 and 429 and 5xx and network errors wait and retry. Any other 4xx fails for good.
    public static func classify(_ error: Error) -> SendOutcome {
        if error is CancellationError { return .retryLater(after: nil) }
        let mapped = ErrorPolicy.map(error)
        guard let api = error as? ChatAPIError else {
            switch mapped {
            case .rateLimited(let retry): return .retryLater(after: retry)
            case .loginNeeded, .consentRequired, .network, .cancelled: return .retryLater(after: nil)
            case .unavailable: return .failedPermanently(reason: "unavailable")
            default: return .retryLater(after: nil)
            }
        }
        switch api {
        case .network, .timeout, .cancelled, .decoding: return .retryLater(after: nil)
        case .http(let status, _, let retry):
            if status == 401 || status == 429 { return .retryLater(after: retry) }
            if (400..<500).contains(status) { return .failedPermanently(reason: "http_\(status)") }
            return .retryLater(after: nil)
        }
    }
}

/// Sends the queue in order. One drain at a time.
public actor Outbox {
    public enum Update: Equatable, Sendable {
        case changed
        case sent(clientMessageId: String, receipt: SendReceipt)
        case failed(clientMessageId: String, reason: String)
    }

    public typealias Sender = @Sendable (QueuedMessage) async throws -> SendReceipt
    public typealias Listener = @Sendable (Update) -> Void

    public let queue: OfflineQueue
    private let clock: ChatClock
    private let random: RandomSource
    private let sender: Sender
    private var listener: Listener?
    private var draining = false
    private var task: Task<Void, Never>?
    private var online = true

    public init(queue: OfflineQueue, clock: ChatClock = SystemClock(), random: RandomSource = SystemRandom(), sender: @escaping Sender) {
        self.queue = queue
        self.clock = clock
        self.random = random
        self.sender = sender
    }

    public func setListener(_ listener: Listener?) { self.listener = listener }

    /// Starts a drain when none runs.
    public func kick() {
        guard !draining else { return }
        draining = true
        task = Task { [weak self] in
            await self?.drain()
        }
    }

    public func networkReturned() { online = true; kick() }
    public func networkLost() { online = false }

    public func cancelAll() {
        task?.cancel()
        task = nil
        draining = false
    }

    /// One full pass. Public so tests can await it.
    public func drain() async {
        defer { draining = false }
        var waitAttempt = 0
        while !Task.isCancelled {
            for id in queue.expireOld() { listener?(.failed(clientMessageId: id, reason: "expired")) }
            guard let next = queue.pending.first else { return }
            queue.recordAttempt(next.clientMessageId)
            do {
                let receipt = try await sender(next)
                queue.remove(next.clientMessageId)
                listener?(.sent(clientMessageId: next.clientMessageId, receipt: receipt))
                waitAttempt = 0
            } catch {
                switch OutboxPolicy.classify(error) {
                case .failedPermanently(let reason):
                    queue.markFailed(next.clientMessageId, reason: reason)
                    listener?(.failed(clientMessageId: next.clientMessageId, reason: reason))
                case .retryLater(let after):
                    listener?(.changed)
                    let delay = after ?? Backoff.delay(attempt: waitAttempt, random: random)
                    waitAttempt += 1
                    do { try await clock.sleep(seconds: min(delay, 300)) } catch { return }
                case .sent:
                    break
                }
            }
        }
    }
}
