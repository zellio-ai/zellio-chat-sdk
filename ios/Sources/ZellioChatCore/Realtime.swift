import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var name: String?
    public var data: String
    public var id: String?
}

/// Incremental server-sent events parser. Feed bytes as they arrive.
/// Handles LF, CRLF and CR line ends, comments (`: ping`), multi-line data, and chunks that split a line or a UTF-8 character.
public struct SSEParser: Sendable {
    private var buffer = [UInt8]()
    private var name: String?
    private var dataLines = [String]()
    private var lastId: String?
    private var sawCR = false

    public init() {}

    public mutating func feed(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            if byte == 10 {                  // LF
                if sawCR { sawCR = false; continue }   // second half of CRLF
                finishLine(&events)
            } else if byte == 13 {           // CR
                sawCR = true
                finishLine(&events)
            } else {
                sawCR = false
                buffer.append(byte)
            }
        }
        return events
    }

    private mutating func finishLine(_ events: inout [SSEEvent]) {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.isEmpty {
            // A blank line ends the event.
            if !dataLines.isEmpty || name != nil {
                events.append(SSEEvent(name: name, data: dataLines.joined(separator: "\n"), id: lastId))
            }
            name = nil
            dataLines = []
            return
        }
        if line.hasPrefix(":") { return }    // comment, for example ": ping"
        var field = line
        var value = ""
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = String(rest)
        }
        switch field {
        case "event": name = value
        case "data": dataLines.append(value)
        case "id": lastId = value
        default: break    // retry and unknown fields are ignored
        }
    }
}

/// Reconnect delays: 1, 2, 4, 8, 16, then 30 seconds, each with jitter.
public struct Backoff: Sendable {
    public static let steps: [Double] = [1, 2, 4, 8, 16, 30]
    public static let jitter = 0.25

    /// `attempt` starts at 0. Jitter spreads the delay by plus or minus 25 percent.
    public static func delay(attempt: Int, random: RandomSource) -> Double {
        let base = steps[min(max(attempt, 0), steps.count - 1)]
        let spread = (random.unit() * 2 - 1) * jitter
        return base * (1 + spread)
    }

    public static func baseDelay(attempt: Int) -> Double { steps[min(max(attempt, 0), steps.count - 1)] }
}

public enum StreamState: Equatable, Sendable {
    case idle
    case connecting
    case open
    case waiting(attempt: Int)
    case paused    // app is in the background
}

public enum StreamInput: Equatable, Sendable {
    case start
    case opened
    case bytes
    case ended           // closed by the server (10 minutes) or lost
    case failed
    case deadTimeout     // 45 s with no bytes
    case enteredBackground
    case enteredForeground
    case stop
}

public enum StreamAction: Equatable, Sendable {
    case connect
    case closeConnection
    case scheduleReconnect(attempt: Int)
    /// Read /unread, then messages with `after`, then reopen the stream.
    case catchUp
}

/// The reconnect rules as a pure function of state and input.
public struct StreamMachine: Sendable {
    public private(set) var state: StreamState = .idle
    public private(set) var wanted = false
    private var attempt = 0

    public static let deadAfter: TimeInterval = 45

    public init() {}

    public mutating func handle(_ input: StreamInput) -> [StreamAction] {
        switch input {
        case .start:
            wanted = true
            guard state == .idle || state == .paused else { return [] }
            attempt = 0
            state = .connecting
            return [.connect]
        case .opened:
            guard state == .connecting else { return [] }
            attempt = 0
            state = .open
            return []
        case .bytes:
            return []
        case .ended, .failed, .deadTimeout:
            guard wanted, state == .connecting || state == .open else { return [] }
            let next = attempt
            attempt += 1
            state = .waiting(attempt: next)
            var actions: [StreamAction] = []
            if input == .deadTimeout { actions.append(.closeConnection) }
            actions.append(.scheduleReconnect(attempt: next))
            return actions
        case .enteredBackground:
            guard wanted else { return [] }
            let wasLive = state != .idle && state != .paused
            state = .paused
            return wasLive ? [.closeConnection] : []
        case .enteredForeground:
            guard wanted, state == .paused else { return [] }
            attempt = 0
            state = .connecting
            return [.catchUp]
        case .stop:
            wanted = false
            let wasLive = state != .idle
            state = .idle
            attempt = 0
            return wasLive ? [.closeConnection] : []
        }
    }

    /// The reconnect timer fired.
    public mutating func reconnectTimerFired() -> [StreamAction] {
        guard wanted, case .waiting = state else { return [] }
        state = .connecting
        return [.catchUp]
    }
}

/// Runs the stream: connect, parse, reconnect with backoff, catch up after every gap.
public actor RealtimeClient {
    public typealias TokenSource = @Sendable () async throws -> String
    public typealias EventHandler = @Sendable (RealtimeEvent) -> Void
    public typealias CatchUp = @Sendable () async -> Void
    public typealias AuthFailure = @Sendable (ChatAPIError) async -> Void

    private let api: ChatAPI
    private let clock: ChatClock
    private let random: RandomSource
    private let tokenSource: TokenSource
    private let onEvent: EventHandler
    private let catchUp: CatchUp
    private let onFailure: AuthFailure
    private var machine = StreamMachine()
    private var loop: Task<Void, Never>?
    private var generation = 0

    public init(api: ChatAPI, clock: ChatClock = SystemClock(), random: RandomSource = SystemRandom(),
                tokenSource: @escaping TokenSource, onEvent: @escaping EventHandler,
                catchUp: @escaping CatchUp, onFailure: @escaping AuthFailure) {
        self.api = api
        self.clock = clock
        self.random = random
        self.tokenSource = tokenSource
        self.onEvent = onEvent
        self.catchUp = catchUp
        self.onFailure = onFailure
    }

    public var state: StreamState { machine.state }

    public func start() { apply(machine.handle(.start)) }
    public func stop() { apply(machine.handle(.stop)) }
    public func enteredBackground() { apply(machine.handle(.enteredBackground)) }
    public func enteredForeground() { apply(machine.handle(.enteredForeground)) }

    private func apply(_ actions: [StreamAction]) {
        for action in actions {
            switch action {
            case .connect, .catchUp:
                launch(initialDelay: 0, runCatchUp: action == .catchUp)
            case .closeConnection:
                generation += 1
                loop?.cancel()
                loop = nil
            case .scheduleReconnect(let attempt):
                launch(initialDelay: Backoff.delay(attempt: attempt, random: random), runCatchUp: true, fromTimer: true)
            }
        }
    }

    private func launch(initialDelay: Double, runCatchUp: Bool, fromTimer: Bool = false) {
        generation += 1
        let mine = generation
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.run(generation: mine, delay: initialDelay, runCatchUp: runCatchUp, fromTimer: fromTimer)
        }
    }

    private func isCurrent(_ mine: Int) -> Bool { mine == generation && !Task.isCancelled }

    private func run(generation mine: Int, delay: Double, runCatchUp: Bool, fromTimer: Bool) async {
        if delay > 0 {
            do { try await clock.sleep(seconds: delay) } catch { return }
        }
        guard isCurrent(mine) else { return }
        if fromTimer {
            let actions = machine.reconnectTimerFired()
            if actions.isEmpty { return }
        }
        if runCatchUp { await catchUp() }
        guard isCurrent(mine) else { return }

        let token: String
        do { token = try await tokenSource() } catch {
            await ended(mine, input: .failed)
            return
        }
        guard isCurrent(mine) else { return }

        let lastByte = Locked(clock.now())
        let dead = Locked(false)
        let stream = api.openStream(token: token)
        let reader: Task<ChatAPIError?, Never> = Task { [weak self, clock] in
            var parser = SSEParser()
            do {
                for try await chunk in stream {
                    lastByte.with { $0 = clock.now() }
                    switch chunk {
                    case .opened:
                        await self?.opened(mine)
                    case .data(let data):
                        for event in parser.feed(data) {
                            if let decoded = RealtimeEventDecoder.decode(event) { await self?.deliver(decoded, generation: mine) }
                        }
                    }
                }
                return nil as ChatAPIError?
            } catch let error as ChatAPIError {
                return error
            } catch {
                return ChatAPIError.network
            }
        }
        let watchdog = Task { [clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: 5) } catch { return }
                let quiet = clock.now().timeIntervalSince(lastByte.snapshot)
                if quiet >= StreamMachine.deadAfter {
                    dead.with { $0 = true }
                    reader.cancel()
                    return
                }
            }
        }
        let failure = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        watchdog.cancel()
        guard isCurrent(mine) else { return }
        if let failure = failure {
            if failure.status == 401 || failure.status == 403 || failure.status == 426 {
                await onFailure(failure)
            }
            // These do not change by trying again. `start()` opens the stream later.
            let reaction = ErrorPolicy.reaction(for: failure)
            if reaction == .stopUnavailable || reaction == .showLoginNeeded {
                guard isCurrent(mine) else { return }
                apply(machine.handle(.stop))
                return
            }
            if case .http(429, _, let retryAfter?) = failure, retryAfter > 0 {
                do { try await clock.sleep(seconds: min(retryAfter, 300)) } catch { return }
                guard isCurrent(mine) else { return }
            }
        }
        await ended(mine, input: dead.snapshot ? .deadTimeout : (failure == nil ? .ended : .failed))
    }

    private func opened(_ mine: Int) {
        guard mine == generation else { return }
        _ = machine.handle(.opened)
    }

    private func deliver(_ event: RealtimeEvent, generation mine: Int) {
        guard mine == generation else { return }
        onEvent(event)
    }

    private func ended(_ mine: Int, input: StreamInput) async {
        guard mine == generation else { return }
        apply(machine.handle(input))
    }
}
