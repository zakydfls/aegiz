import Foundation
import LocalAuthentication
import Security

enum KeychainVaultError: LocalizedError {
    case invalidSecret
    case unexpectedResult
    case security(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            "A secret needs a name and a value."
        case .unexpectedResult:
            "Keychain returned an unexpected result."
        case .security(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain: \(message)"
            } else {
                "Keychain operation failed with status \(status)."
            }
        }
    }
}

struct VaultStatusModel: Sendable {
    let masterKeyReady: Bool
    let userPresenceAvailable: Bool
    let authenticationLabel: String
}

actor KeychainVault {
    private let service: String
    private let masterKeyAccount = "master-key-v1"
    private let secretPrefix = "secret."

    init() {
        service = "dev.aegiz.desktop.local-vault"
    }

    #if DEBUG
    init(fixtureService: String) {
        precondition(fixtureService.hasPrefix("dev.aegiz.desktop.fixture."))
        service = fixtureService
    }
    #endif

    func prepare() throws -> VaultStatusModel {
        try ensureMasterKey()
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        let label: String
        switch context.biometryType {
        case .touchID:
            label = "Touch ID"
        case .opticID:
            label = "Optic ID"
        case .faceID:
            label = "Face ID"
        default:
            label = "device authentication"
        }
        return VaultStatusModel(
            masterKeyReady: true,
            userPresenceAvailable: available,
            authenticationLabel: label
        )
    }

    func listSecrets() throws -> [SecretMetadataModel] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainVaultError.security(status)
        }
        let attributes: [[String: Any]]
        if let values = result as? [[String: Any]] {
            attributes = values
        } else if let value = result as? [String: Any] {
            attributes = [value]
        } else {
            throw KeychainVaultError.unexpectedResult
        }
        return attributes.compactMap(secretMetadata).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func saveSecret(
        _ draft: SecretDraft,
        replacingID: String? = nil
    ) throws -> SecretMetadataModel {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !draft.value.isEmpty else {
            throw KeychainVaultError.invalidSecret
        }
        guard trimmedName.utf8.count <= 200, draft.value.utf8.count <= 64 * 1024 else {
            throw KeychainVaultError.invalidSecret
        }

        let id = replacingID ?? UUID().uuidString.lowercased()
        let account = "\(secretPrefix)\(id)"
        let metadata = SecretRecordMetadata(
            kind: draft.kind.rawValue,
            requiresUserPresence: draft.requiresUserPresence
        )
        let metadataData = try JSONEncoder().encode(metadata)
        let secretData = Data(draft.value.utf8)
        if replacingID == nil {
            var attributes = baseQuery(account: account)
            attributes[kSecAttrLabel as String] = trimmedName
            attributes[kSecAttrDescription as String] = "Aegiz local secret reference"
            attributes[kSecAttrGeneric as String] = metadataData
            attributes[kSecValueData as String] = secretData
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainVaultError.security(status)
            }
        } else {
            let updates: [String: Any] = [
                kSecAttrLabel as String: trimmedName,
                kSecAttrGeneric as String: metadataData,
                kSecValueData as String: secretData,
            ]
            let status = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                updates as CFDictionary
            )
            guard status == errSecSuccess else {
                throw KeychainVaultError.security(status)
            }
        }
        let prior = try listSecrets().first { $0.id == id }
        return SecretMetadataModel(
            id: id,
            name: trimmedName,
            kind: draft.kind,
            requiresUserPresence: draft.requiresUserPresence,
            createdAt: prior?.createdAt ?? Date(),
            modifiedAt: Date()
        )
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }

    func revealSecret(
        id: String,
        reason: String,
        authenticationAlreadySatisfied: Bool = false
    ) async throws -> Data {
        let secrets = try listSecrets()
        guard let secret = secrets.first(where: { $0.id == id }) else {
            throw KeychainVaultError.security(errSecItemNotFound)
        }
        if secret.requiresUserPresence, !authenticationAlreadySatisfied {
            try await authenticate(reason: reason)
        }
        var query = baseQuery(account: "\(secretPrefix)\(id)")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainVaultError.security(status)
        }
        guard let data = result as? Data else {
            throw KeychainVaultError.unexpectedResult
        }
        return data
    }

    func deleteSecret(id: String) throws {
        let status = SecItemDelete(
            baseQuery(account: "\(secretPrefix)\(id)") as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.security(status)
        }
    }

    private func ensureMasterKey() throws {
        var query = baseQuery(account: masterKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard (result as? Data)?.count == 32 else {
                throw KeychainVaultError.unexpectedResult
            }
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainVaultError.security(status)
        }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw KeychainVaultError.security(randomStatus)
        }
        var attributes = baseQuery(account: masterKeyAccount)
        attributes[kSecAttrLabel as String] = "Aegiz local vault master key"
        attributes[kSecValueData as String] = key
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        key.resetBytes(in: 0..<key.count)
        guard addStatus == errSecSuccess else {
            throw KeychainVaultError.security(addStatus)
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private func secretMetadata(_ attributes: [String: Any]) -> SecretMetadataModel? {
        guard let account = attributes[kSecAttrAccount as String] as? String,
              account.hasPrefix(secretPrefix)
        else {
            return nil
        }
        let metadata: SecretRecordMetadata
        if let data = attributes[kSecAttrGeneric as String] as? Data,
           let decoded = try? JSONDecoder().decode(SecretRecordMetadata.self, from: data) {
            metadata = decoded
        } else {
            metadata = SecretRecordMetadata(kind: SecretKindModel.generic.rawValue)
        }
        return SecretMetadataModel(
            id: String(account.dropFirst(secretPrefix.count)),
            name: attributes[kSecAttrLabel as String] as? String ?? "Unnamed secret",
            kind: SecretKindModel(rawValue: metadata.kind) ?? .generic,
            requiresUserPresence: metadata.requiresUserPresence,
            createdAt: attributes[kSecAttrCreationDate as String] as? Date ?? .distantPast,
            modifiedAt: attributes[kSecAttrModificationDate as String] as? Date ?? .distantPast
        )
    }
}

private struct SecretRecordMetadata: Codable {
    let kind: String
    var requiresUserPresence = false
}
