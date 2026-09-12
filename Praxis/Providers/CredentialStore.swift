import Foundation
import Security

/// Keychain-backed secret storage.
///
/// Secrets never touch `UserDefaults`, never get logged, and never leave the
/// device except as an `Authorization` / `x-api-key` header to the provider
/// the learner chose. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// keeps them off iCloud Keychain and off device backups.
struct CredentialStore {

    enum Key: String, CaseIterable {
        case anthropicAPIKey = "anthropic.api-key"
        case awsAccessKeyID = "aws.access-key-id"
        case awsSecretAccessKey = "aws.secret-access-key"
        case awsSessionToken = "aws.session-token"
        /// Optional. Lets the learner raise GitHub's 60 req/hr anonymous
        /// limit during docs sync; the app works fine without it.
        case githubToken = "github.token"
    }

    private let service: String

    init(service: String = "com.praxis.tutor.credentials") {
        self.service = service
    }

    // MARK: Read / write

    func value(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    @discardableResult
    func set(_ value: String?, for key: Key) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return remove(key) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func has(_ key: Key) -> Bool { value(for: key) != nil }

    /// Wipe everything. Offered in Settings so the learner can hand the device
    /// on without leaving keys behind.
    func removeAll() {
        for key in Key.allCases { remove(key) }
    }

    // MARK: Derived checks

    var hasAnthropicCredentials: Bool { has(.anthropicAPIKey) }

    var hasAWSCredentials: Bool { has(.awsAccessKeyID) && has(.awsSecretAccessKey) }

    func awsCredentials() -> AWSCredentials? {
        guard let accessKey = value(for: .awsAccessKeyID),
              let secret = value(for: .awsSecretAccessKey) else { return nil }
        return AWSCredentials(
            accessKeyID: accessKey,
            secretAccessKey: secret,
            sessionToken: value(for: .awsSessionToken)
        )
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
