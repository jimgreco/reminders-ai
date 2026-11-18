import Foundation
import Security

/// Session tokens live in the Keychain, readable only while the device is
/// unlocked and never synced to iCloud or restored to another device.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.jimgreco.remindersai" }

    static func read(_ key: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, key: String) {
        delete(key)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ] as CFDictionary)
    }
}
