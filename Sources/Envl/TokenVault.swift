import Foundation
import Security

struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

protocol MailTokenVault: Sendable {
    func load(accountID: String) async throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens, accountID: String) async throws
    func remove(accountID: String) async throws
}

/// Accessed only when a connected account performs an operation, never while listing accounts.
actor KeychainMailTokenVault: MailTokenVault {
    private let service = "com.berkin.menumail.oauth"

    func load(accountID: String) throws -> OAuthTokens? {
        var query = query(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DirectMailError.tokenStorage(status)
        }
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            throw DirectMailError.reauthorizationRequired
        }
        return tokens
    }

    func save(_ tokens: OAuthTokens, accountID: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = query(accountID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw DirectMailError.tokenStorage(added) }
        } else if status != errSecSuccess {
            throw DirectMailError.tokenStorage(status)
        }
    }

    func remove(accountID: String) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectMailError.tokenStorage(status) }
    }

    private func query(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: accountID,
         kSecAttrSynchronizable as String: false]
    }
}

protocol DirectMailAccountStorage: Sendable {
    func load() async throws -> [MailAccount]
    func save(_ accounts: [MailAccount]) async throws
}

/// Contains account descriptors only. Message bodies and authorization never enter UserDefaults.
actor UserDefaultsMailAccountStorage: DirectMailAccountStorage {
    private let defaults = UserDefaults.standard
    private let key = "directMailAccounts.v1"

    func load() throws -> [MailAccount] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) else {
            throw DirectMailError.accountStorage
        }
        return accounts.filter { $0.provider == .gmail || $0.provider == .outlook }
    }

    func save(_ accounts: [MailAccount]) throws { defaults.set(try JSONEncoder().encode(accounts), forKey: key) }
}
