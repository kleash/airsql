// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Keychain.swift (without its Porter migration).
import Foundation
import os
import Security

/// Saved passwords: one login-Keychain item (service com.kleash.airsql) holding a JSON dictionary keyed by connection
/// id (and later by SSH hop and proxy keys), so macOS asks for access once per app build instead of once per
/// connection. Cached after the first read. When the item can't be read (access denied, a locked keychain), nothing is
/// cached and nothing is written: a save then would replace every other saved password.
/// A throwaway AirSQL (`memoryOnly`: AIRSQL_SUPPORT_DIR set, as tests, smoke runs and agents' instances do) never
/// touches the login Keychain: its saved passwords stay in memory until it quits.
/// Reading may wait for the person (a locked keychain): call it off the main thread.
public enum Keychain {
    static let service = "com.kleash.airsql"
    private static let account = "passwords"
    private static let log = Logger(subsystem: "com.kleash.airsql", category: "keychain")
    private static let lock = NSLock()
    static var cache: [String: String]?
    /// Passwords are kept in memory only, never in the login Keychain: true for a throwaway instance.
    public static var memoryOnly = Env.isThrowaway()

    /// The status and data of AirSQL's item, and writing new data to it. Tests replace them (they never touch the
    /// login Keychain).
    static var readItem: () -> (status: OSStatus, data: Data?) = {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    static var writeItem: (Data) -> OSStatus = { data in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "AirSQL saved passwords"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    public static func password(for connectionID: UUID) -> String? {
        password(forKey: connectionID.uuidString)
    }

    /// Saves the password, or removes it when `password` is nil.
    public static func setPassword(_ password: String?, for connectionID: UUID) {
        setPassword(password, forKey: connectionID.uuidString)
    }

    public static func password(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return all()?[key]
    }

    /// Saves the password under `key`, or removes it when `password` is nil. Not when the item can't be read.
    public static func setPassword(_ password: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var passwords = all() else {
            log.error("Keychain: not saved, the saved passwords couldn't be read")
            return
        }
        passwords[key] = password
        cache = passwords
        guard !memoryOnly, let data = try? JSONEncoder().encode(passwords) else { return }
        let status = writeItem(data)
        if status != errSecSuccess { log.error("Keychain write failed: \(status, privacy: .public)") }
    }

    /// The saved passwords (none when there is no item yet), or nil when the item couldn't be read.
    private static func all() -> [String: String]? {
        if let cache { return cache }
        if memoryOnly {
            cache = [:]
            return cache
        }
        let (status, data) = readItem()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("Keychain read failed: \(status, privacy: .public)")
            return nil
        }
        let passwords = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = passwords
        return passwords
    }
}
