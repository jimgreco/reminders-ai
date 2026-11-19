import Foundation
import Security

/// Session tokens live in the Keychain, never synced to iCloud or restored to
/// another device. They stay readable after the first unlock since a reboot,
/// so a push that wakes the app on a locked phone can still sync.
enum Keychain {
    enum Lookup: Equatable {
        case value(String)
        case missing
        /// The item may exist but can't be read now (the phone hasn't been unlocked since it restarted).
        case unavailable
    }

    private static var service: String { Bundle.main.bundleIdentifier ?? "com.jimgreco.remindersai" }
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func lookup(_ key: String) -> Lookup {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .missing }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    static func read(_ key: String) -> String? {
        if case .value(let value) = lookup(key) { return value }
        return nil
    }

    /// Updates in place so a failed write never leaves the old token deleted.
    static func write(_ value: String, key: String) {
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8), kSecAttrAccessible: accessible]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        SecItemAdd(query(key).merging(attributes) { $1 } as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    /// Moves items saved by earlier builds (readable only while unlocked) to
    /// the after-first-unlock class. Harmless when there's nothing to move.
    static func upgradeAccessibility(_ keys: [String]) {
        for key in keys {
            SecItemUpdate(query(key) as CFDictionary, [kSecAttrAccessible: accessible] as CFDictionary)
        }
    }
}
