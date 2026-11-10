import Foundation

public struct ThreadSnapshot: Equatable, Sendable {
    public var conversationId: String?
    public var messages: [ChatMessage] = []
    public var hasOlder = false
    public var isLoadingOlder = false
    public var isLoading = true
    public var typing = false
    public var typingName: String?
    public var error: ChatError?
    public var canAttach = true
    /// Counts agent messages that arrived live. The view uses it for the "New message" pill, the tick and the announcement.
    public var incomingCount = 0
    /// True when a visible message changed in place or was added at the end by this controller.
    public var revision = 0

    public init(conversationId: String? = nil) { self.conversationId = conversationId }
}

/// The logic of one thread: load, page, send, retry, merge live messages. The view only draws snapshots.
public actor ThreadController {
    public typealias Observer = @Sendable (ThreadSnapshot) -> Void

    private let engine: ChatEngine
    private var timeline = Timeline()
    private var snapshot: ThreadSnapshot
    private var observer: Observer?
    private var listenerToken: Int?
    private var typingTask: Task<Void, Never>?
    private var reloadedForExpiredAttachment = false
    private var started = false

    public init(engine: ChatEngine, conversationId: String?) {
        self.engine = engine
        self.snapshot = ThreadSnapshot(conversationId: conversationId)
    }

    public func setObserver(_ observer: Observer?) {
        self.observer = observer
        observer?(snapshot)
    }

    public var conversationId: String? { snapshot.conversationId }

    private func publish() {
        snapshot.messages = timeline.messages
        snapshot.hasOlder = timeline.hasOlder
        snapshot.revision += 1
        observer?(snapshot)
    }

    // MARK: Start and stop

    /// Draws what is saved at once, then reads the newest page.
    public func start() async {
        guard !started else { return }
        started = true
        if let id = snapshot.conversationId, let saved = engine.storage.load(Timeline.self, StorageName.messages(id)) {
            timeline = saved
        }
        snapshot.canAttach = engine.cachedConfig?.snapshot.behavior.allowAttachments ?? true
        mergeQueue()
        snapshot.isLoading = timeline.messages.isEmpty && snapshot.conversationId != nil
        publish()

        let engineRef = engine
        let token = engineRef.addListener { [weak self] event in
            guard let self = self else { return }
            Task { await self.handle(event) }
        }
        listenerToken = token

        await loadLatest()
        await engine.outbox.kick()
    }

    public func stop() {
        if let token = listenerToken { engine.removeListener(token) }
        listenerToken = nil
        typingTask?.cancel()
        observer = nil
        persist()
    }

    private func persist() {
        guard let id = snapshot.conversationId else { return }
        engine.storage.save(timeline.persisted(), StorageName.messages(id))
    }

    // MARK: Loading

    private func loadLatest() async {
        guard let id = snapshot.conversationId else {
            snapshot.isLoading = false
            publish()
            return
        }
        do {
            let page = try await engine.session.perform { token in try await self.engine.api.messages(conversationId: id, token: token) }
            timeline.apply(page: page, older: false, initial: true)
            timeline.trim()
            snapshot.error = nil
            snapshot.isLoading = false
            mergeQueue()
            persist()
            publish()
            await markReadIfNeeded()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let mapped = ErrorPolicy.map(error)
        snapshot.isLoading = false
        // A thread that has messages keeps them. The view shows a banner, not an empty error screen.
        snapshot.error = mapped
        publish()
        if mapped == .conversationNotFound { Task { _ = try? await engine.loadConversations() } }
    }

    public func retryLoad() async {
        snapshot.isLoading = timeline.messages.isEmpty
        snapshot.error = nil
        publish()
        await loadLatest()
    }

    /// Older messages, when the customer scrolls to the top.
    public func loadOlder() async {
        guard let id = snapshot.conversationId, let cursor = timeline.nextBefore, !snapshot.isLoadingOlder else { return }
        snapshot.isLoadingOlder = true
        publish()
        do {
            let page = try await engine.session.perform { token in try await self.engine.api.messages(conversationId: id, before: cursor, token: token) }
            timeline.apply(page: page, older: true)
            snapshot.isLoadingOlder = false
            persist()
            publish()
        } catch {
            snapshot.isLoadingOlder = false
            publish()
        }
    }

    /// Reads messages newer than the last one we have. Used after a gap: reconnect, foreground, push.
    public func catchUp() async {
        if snapshot.conversationId == nil { await adoptConversationFromList() }
        guard let id = snapshot.conversationId else { return }
        guard let cursor = timeline.latest else { await loadLatest(); return }
        do {
            let page = try await engine.session.perform { token in try await self.engine.api.messages(conversationId: id, after: cursor, token: token) }
            let before = timeline.messages.count
            timeline.apply(page: page, older: false)
            timeline.trim()
            countIncoming(timeline.messages.count - before, in: page.messages)
            snapshot.error = nil
            persist()
            publish()
            await markReadIfNeeded()
        } catch {
            if ErrorPolicy.map(error) == .conversationNotFound { fail(error) }
        }
    }

    /// An attachment URL expired (403): read the page again, once.
    public func reloadAfterExpiredAttachment() async {
        guard !reloadedForExpiredAttachment else { return }
        reloadedForExpiredAttachment = true
        await loadLatest()
    }

    private func adoptConversationFromList() async {
        guard let page = try? await engine.loadConversations(), let newest = page.conversations.first else { return }
        guard timeline.messages.contains(where: { $0.from == .visitor }) else { return }
        snapshot.conversationId = newest.id
    }

    private func countIncoming(_ added: Int, in messages: [ChatMessage]) {
        guard added > 0 else { return }
        snapshot.incomingCount += messages.filter { $0.from == .agent }.count
    }

    private func markReadIfNeeded() async {
        guard let id = snapshot.conversationId,
              let last = timeline.messages.last(where: { $0.from == .agent && $0.serverId != nil }),
              let serverId = last.serverId else { return }
        await engine.markRead(conversationId: id, upTo: serverId)
    }

    // MARK: Live events

    private func handle(_ event: HubEvent) async {
        switch event {
        case .localDataWiped:
            break
        case .reconnected:
            await catchUp()
        case .outbox(let update):
            handleOutbox(update)
        case .realtime(let realtime):
            switch realtime {
            case .ready(let id):
                if snapshot.conversationId == nil, let id = id, timeline.messages.contains(where: { $0.from == .visitor }) {
                    snapshot.conversationId = id
                    publish()
                }
            case .message(let message, let conversationId):
                guard accepts(streamConversation: conversationId ?? engine.streamConversationId) else { return }
                if snapshot.conversationId == nil, let conversationId = conversationId { snapshot.conversationId = conversationId }
                let isNew = !timeline.messages.contains { ($0.serverId != nil && $0.serverId == message.serverId) || ($0.clientMessageId != nil && $0.clientMessageId == message.clientMessageId) }
                timeline.upsert(message)
                timeline.trim()
                if isNew && message.from == .agent {
                    snapshot.incomingCount += 1
                    snapshot.typing = false
                }
                persist()
                publish()
                if message.from == .agent { await markReadIfNeeded() }
            case .typing(let active, let name):
                setTyping(active, name: name)
            case .agentJoined:
                break
            case .unread:
                break
            }
        }
    }

    private func accepts(streamConversation: String?) -> Bool {
        guard let mine = snapshot.conversationId else { return true }
        return streamConversation == nil || streamConversation == mine
    }

    private func setTyping(_ active: Bool, name: String?) {
        typingTask?.cancel()
        snapshot.typing = active
        snapshot.typingName = active ? name : nil
        publish()
        if active {
            // Safety: if the "stopped" event is lost, the dots go away after 12 seconds.
            typingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { return }
                await self?.clearTyping()
            }
        }
    }

    private func clearTyping() {
        snapshot.typing = false
        publish()
    }

    // MARK: Sending

    /// Saves the message to the queue first, shows it at once, then sends. Returns the client id.
    @discardableResult
    public func send(text: String, attachments: [Attachment] = []) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty { return nil }
        let item = engine.queue.enqueue(text: trimmed.clipped(toUTF16: 4000), attachments: attachments, context: engine.context, conversationId: snapshot.conversationId)
        timeline.upsert(item.asMessage(delivery: .sending))
        engine.drafts.set("", conversationId: snapshot.conversationId)
        publish()
        let engineRef = engine
        Task { await engineRef.outbox.kick() }
        return item.clientMessageId
    }

    /// "Try again" on a failed message.
    public func retry(clientMessageId: String) {
        engine.queue.retry(clientMessageId)
        timeline.setDelivery(clientMessageId: clientMessageId, .sending)
        publish()
        let engineRef = engine
        Task { await engineRef.outbox.kick() }
    }

    private func handleOutbox(_ update: Outbox.Update) {
        switch update {
        case .changed:
            for item in engine.queue.pending where item.attempts > 0 {
                timeline.setDelivery(clientMessageId: item.clientMessageId, .waiting)
            }
            publish()
        case .sent(let cid, let receipt):
            timeline.setDelivery(clientMessageId: cid, .sent)
            if snapshot.conversationId == nil, let id = receipt.conversationId { snapshot.conversationId = id }
            publish()
            // The server copy arrives by the stream. If it does not, this read finds it.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.catchUp()
            }
        case .failed(let cid, let reason):
            timeline.setDelivery(clientMessageId: cid, .failed, reason: reason)
            publish()
        }
    }

    /// Puts queue items that are not in the list yet into it. Used at start, after a restart.
    private func mergeQueue() {
        for item in engine.queue.all where item.conversationId == nil || item.conversationId == snapshot.conversationId {
            let delivery: DeliveryState = item.status == .failed ? .failed : (item.attempts > 0 ? .waiting : .sending)
            if timeline.messages.contains(where: { $0.clientMessageId == item.clientMessageId && $0.serverId != nil }) { continue }
            var message = item.asMessage(delivery: delivery)
            message.failureReason = item.failureReason
            timeline.upsert(message)
        }
    }

    // MARK: Draft

    public func draft() -> String { engine.drafts.get(snapshot.conversationId) }
    public func saveDraft(_ text: String) { engine.drafts.set(text, conversationId: snapshot.conversationId) }
}
