import Foundation

/// Private local storage. The app target gives a file version that is excluded from backups.
public protocol StorageBackend: Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data)
    func remove(_ name: String)
    /// Removes every entry except the listed names.
    func removeAll(keeping: Set<String>)
    func names() -> [String]
}

public final class MemoryStorage: StorageBackend, @unchecked Sendable {
    private let store = Locked<[String: Data]>([:])
    public init() {}
    public func read(_ name: String) -> Data? { store.with { $0[name] } }
    public func write(_ name: String, _ data: Data) { store.with { $0[name] = data } }
    public func remove(_ name: String) { store.with { $0[name] = nil } }
    public func removeAll(keeping: Set<String>) { store.with { dict in dict = dict.filter { keeping.contains($0.key) } } }
    public func names() -> [String] { store.with { Array($0.keys) } }
}

public final class FileStorage: StorageBackend, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory.appendingPathComponent(safe)
    }

    public func read(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: url(name))
    }

    public func write(_ name: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(name), options: .atomic)
    }

    public func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(name))
    }

    public func removeAll(keeping: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for item in items where !keeping.contains(item) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    public func names() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}

/// The session token lives here. The app target gives a Keychain version.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, value: String)
    func delete(_ key: String)
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let store = Locked<[String: String]>([:])
    public init() {}
    public func read(_ key: String) -> String? { store.with { $0[key] } }
    public func write(_ key: String, value: String) { store.with { $0[key] = value } }
    public func delete(_ key: String) { store.with { $0[key] = nil } }
}

extension StorageBackend {
    /// Reads a JSON value. A file that does not decode is removed.
    public func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = read(name) else { return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        remove(name)
        return nil
    }

    public func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { write(name, data) }
    }
}

public enum StorageName {
    public static let installId = "install.json"
    public static let consent = "consent.json"
    public static let config = "config.json"
    public static let conversations = "conversations.json"
    public static let queue = "queue.json"
    public static let session = "session.json"
    public static let drafts = "drafts.json"
    public static let push = "push.json"
    public static func messages(_ conversationId: String) -> String { "messages-\(conversationId).json" }

    /// Kept when the customer logs out: these belong to the install. Consent is not kept, because another person can use the phone.
    public static let keptOnLogout: Set<String> = [installId, push]
}

/// The random id of this install. Resets on reinstall because it lives in app storage.
public enum InstallId {
    private struct Box: Codable { var id: String }

    public static func load(_ storage: StorageBackend) -> String {
        if let box = storage.load(Box.self, StorageName.installId), !box.id.isEmpty { return box.id }
        let id = UUID().uuidString.lowercased()
        storage.save(Box(id: id), StorageName.installId)
        return id
    }
}

/// Last good config, saved raw and parsed again on load.
public struct ConfigCache: Sendable {
    private let storage: StorageBackend
    public init(storage: StorageBackend) { self.storage = storage }

    public func save(body: Data) { storage.write(StorageName.config, body) }

    public func load() -> ChatConfig? {
        guard let body = storage.read(StorageName.config) else { return nil }
        if let config = try? ChatConfig.parse(body) { return config }
        storage.remove(StorageName.config)
        return nil
    }
}

/// Draft text by conversation. `nil` key means a new conversation.
public struct DraftStore: Sendable {
    private let storage: StorageBackend
    public init(storage: StorageBackend) { self.storage = storage }

    private func key(_ conversationId: String?) -> String { conversationId ?? "_new" }

    public func get(_ conversationId: String?) -> String {
        (storage.load([String: String].self, StorageName.drafts) ?? [:])[key(conversationId)] ?? ""
    }

    public func set(_ text: String, conversationId: String?) {
        var all = storage.load([String: String].self, StorageName.drafts) ?? [:]
        if text.isEmpty { all[key(conversationId)] = nil } else { all[key(conversationId)] = text }
        storage.save(all, StorageName.drafts)
    }
}

/// What a customer accepts: the consent text and the privacy link, not the rest of the published config.
public struct ConsentTerms: Codable, Equatable, Sendable {
    public var en: String
    public var ar: String
    public var privacyUrl: String

    public init(behavior: Behavior) {
        en = (behavior.consentText.en ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ar = (behavior.consentText.ar ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        privacyUrl = (behavior.privacyUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the customer accepted on this install.
public struct ConsentStore: Sendable {
    private let storage: StorageBackend
    public init(storage: StorageBackend) { self.storage = storage }

    public func isAccepted(_ terms: ConsentTerms) -> Bool {
        storage.load(ConsentTerms.self, StorageName.consent) == terms
    }

    public func accept(_ terms: ConsentTerms) {
        storage.save(terms, StorageName.consent)
    }
}

public enum ConsentState: Equatable, Sendable {
    case notRequired
    case required
    case granted
}

public enum ConsentGate {
    public static func state(config: ChatConfig, store: ConsentStore) -> ConsentState {
        if !config.snapshot.behavior.consentRequired { return .notRequired }
        // A publish that changes only a color or a label must not ask again.
        return store.isAccepted(ConsentTerms(behavior: config.snapshot.behavior)) ? .granted : .required
    }

    /// No session, no history and no stream before Accept.
    public static func allowsSession(config: ChatConfig?, store: ConsentStore) -> Bool {
        guard let config = config else { return false }
        return state(config: config, store: store) != .required
    }
}
