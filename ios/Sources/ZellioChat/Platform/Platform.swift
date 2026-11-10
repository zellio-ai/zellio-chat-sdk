#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Network
import Security
import UIKit
import AudioToolbox
import ZellioChatCore

/// Session token store in the Keychain. Accessible after first unlock, never synced or restored to another device.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "ai.zellio.chat") { self.service = service }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ key: String, value: String) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(_ key: String) {
        _ = SecItemDelete(baseQuery(key) as CFDictionary)
    }
}

enum AppleStorage {
    /// Application Support/ZellioChat/<appKey hash>. Excluded from backups.
    static func make(appKey: String) -> FileStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safeKey = String(appKey.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(48))
        var directory = base.appendingPathComponent("ZellioChat", isDirectory: true).appendingPathComponent(safeKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        // The parent folder too, so no other file of ours is backed up.
        var parent = directory.deletingLastPathComponent()
        try? parent.setResourceValues(values)
        return FileStorage(directory: directory)
    }
}

/// Reports whether the network is reachable.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.zellio.chat.network")
    private let lock = NSLock()
    private var online = true
    var onChange: (@Sendable (Bool) -> Void)?

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let now = path.status == .satisfied
            self.lock.lock()
            let changed = self.online != now
            self.online = now
            self.lock.unlock()
            if changed { self.onChange?(now) }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}

enum Haptics {
    /// A light tap on send.
    static func sendTap() {
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    /// A soft tick on a new message while chat is open.
    static func incomingTick() {
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }

    /// A notice on a failed send.
    static func failure() {
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }

    /// Only when the brand turned sound on. System sounds follow the ring switch.
    static func incomingSound() {
        AudioServicesPlaySystemSound(1007)
    }
}

enum SDKLog {
    static var level: ZellioChatLogLevel = .error

    /// Never pass message text, tokens or identities here.
    static func log(_ level: ZellioChatLogLevel, _ message: @autoclosure () -> String) {
        guard level.rawValue <= SDKLog.level.rawValue, level != .none else { return }
        NSLog("[ZellioChat] %@", message())
    }
}
#endif
