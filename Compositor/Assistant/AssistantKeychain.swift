import Foundation
import Observation
import os
import Security

/// The OpenRouter API key, kept in the login keychain as a generic password: never in the defaults or a project.
nonisolated enum AssistantKeychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "com.wonderassembly.compositor") + ".openrouter" }
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The key once read, so the keychain is asked once a launch: reading a password can make macOS ask the user to
    /// allow it, and a build signed ad hoc is a new app to the keychain every time it's built.
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func read() -> String? {
        if let key = cache.withLock({ $0 }) { return key }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cache.withLock { $0 = key }
        return key
    }

    /// Whether a key is stored, from its attributes alone: unlike its password, they're read without asking the user.
    static func exists() -> Bool {
        if cache.withLock({ $0 }) != nil { return true }
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the stored key; an empty one removes it.
    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { try delete(); return }
        let data = Data(key.utf8)
        // VERIFY(macOS): the sandboxed app reads and writes its own generic password without a keychain-access-groups
        // entitlement (it should, through the app's default access group).
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
        cache.withLock { $0 = key }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        cache.withLock { $0 = nil }
    }
}

nonisolated struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The keychain couldn’t store the API key: \(reason)"
    }
}

/// Whether a key is stored, for the panel and Settings to watch; the keychain itself isn't observable.
@MainActor @Observable
final class AssistantKeyState {
    static let shared = AssistantKeyState()
    private(set) var hasKey = AssistantKeychain.exists()
    func refresh() { hasKey = AssistantKeychain.exists() }
}
