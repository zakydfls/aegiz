import CryptoKit
import Foundation
import Security

enum AegizBackupError: LocalizedError {
    case weakPassphrase
    case invalidFormat
    case unsupportedVersion(Int)
    case oversized
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .weakPassphrase:
            "Use a backup passphrase of at least 12 characters."
        case .invalidFormat:
            "This is not a valid Aegiz encrypted backup."
        case .unsupportedVersion(let version):
            "Backup format \(version) is not supported by this Aegiz build."
        case .oversized:
            "The backup exceeds Aegiz's 64 MiB safety limit."
        case .authenticationFailed:
            "The passphrase is incorrect or the backup was modified."
        }
    }
}

struct AegizBackupPayload: Codable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let coreSnapshot: Data
    let hostOrganization: [String: HostOrganizationMetadata]
    let terminalSettings: [String: TerminalHostSettings]
}

private struct AegizEncryptedBackup: Codable {
    let magic: String
    let formatVersion: Int
    let kdf: String
    let iterations: Int
    let salt: Data
    let sealedPayload: Data
}

enum AegizBackupManager {
    static let fileExtension = "aegizbackup"
    static let maximumFileSize = 64 * 1024 * 1024
    private static let magic = "AEGIZ-LOCAL-BACKUP"
    private static let formatVersion = 1
    private static let iterations = 210_000
    private static let authenticatedContext = Data("dev.aegiz.backup.v1".utf8)

    static func seal(
        _ payload: AegizBackupPayload,
        passphrase: String
    ) throws -> Data {
        try validatePassphrase(passphrase)
        let plaintext = try JSONEncoder.aegiz.encode(payload)
        guard plaintext.count <= maximumFileSize else {
            throw AegizBackupError.oversized
        }
        var salt = Data(count: 16)
        let randomStatus = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw KeychainVaultError.security(randomStatus)
        }
        let key = try PBKDF2SHA256.derive(
            passphrase: passphrase,
            salt: salt,
            iterations: iterations
        )
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedContext
        )
        guard let combined = box.combined else {
            throw AegizBackupError.invalidFormat
        }
        return try JSONEncoder.aegiz.encode(
            AegizEncryptedBackup(
                magic: magic,
                formatVersion: formatVersion,
                kdf: "PBKDF2-HMAC-SHA256",
                iterations: iterations,
                salt: salt,
                sealedPayload: combined
            )
        )
    }

    static func open(
        _ data: Data,
        passphrase: String
    ) throws -> AegizBackupPayload {
        try validatePassphrase(passphrase)
        guard data.count <= maximumFileSize else {
            throw AegizBackupError.oversized
        }
        guard let envelope = try? JSONDecoder.aegiz.decode(
            AegizEncryptedBackup.self,
            from: data
        ), envelope.magic == magic,
           envelope.kdf == "PBKDF2-HMAC-SHA256",
           envelope.salt.count == 16,
           (100_000...1_000_000).contains(envelope.iterations)
        else {
            throw AegizBackupError.invalidFormat
        }
        guard envelope.formatVersion == formatVersion else {
            throw AegizBackupError.unsupportedVersion(envelope.formatVersion)
        }
        let key = try PBKDF2SHA256.derive(
            passphrase: passphrase,
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedContext
            )
            let payload = try JSONDecoder.aegiz.decode(
                AegizBackupPayload.self,
                from: plaintext
            )
            guard payload.schemaVersion == 1 else {
                throw AegizBackupError.unsupportedVersion(payload.schemaVersion)
            }
            return payload
        } catch let error as AegizBackupError {
            throw error
        } catch {
            throw AegizBackupError.authenticationFailed
        }
    }

    private static func validatePassphrase(_ passphrase: String) throws {
        guard passphrase.count >= 12,
              passphrase.utf8.count <= 1_024,
              !passphrase.contains("\0")
        else {
            throw AegizBackupError.weakPassphrase
        }
    }
}

enum PBKDF2SHA256 {
    static func derive(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        guard iterations > 0 else { throw AegizBackupError.invalidFormat }
        var password = Data(passphrase.utf8)
        defer {
            password.resetBytes(in: 0..<password.count)
            password.removeAll(keepingCapacity: false)
        }
        let key = SymmetricKey(data: password)
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])
        var current = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: key))
        var result = current
        if iterations > 1 {
            for _ in 1..<iterations {
                current = Data(HMAC<SHA256>.authenticationCode(for: current, using: key))
                result.withUnsafeMutableBytes { resultBytes in
                    current.withUnsafeBytes { currentBytes in
                        guard let resultBase = resultBytes.baseAddress,
                              let currentBase = currentBytes.baseAddress
                        else { return }
                        for index in 0..<resultBytes.count {
                            resultBase.assumingMemoryBound(to: UInt8.self)[index] ^=
                                currentBase.assumingMemoryBound(to: UInt8.self)[index]
                        }
                    }
                }
            }
        }
        return SymmetricKey(data: result.prefix(32))
    }
}

enum AuditExporter {
    static func json(_ events: [AuditEventModel]) throws -> Data {
        struct Event: Codable {
            let id: Int64
            let occurredAt: Date
            let action: String
            let resourceID: String
            let outcome: String
            let detail: String
        }
        let values = events.map {
            Event(
                id: $0.id,
                occurredAt: $0.occurredAt,
                action: $0.action,
                resourceID: $0.resourceID,
                outcome: $0.outcome,
                detail: $0.detail
            )
        }
        return try JSONEncoder.aegizPretty.encode(values)
    }

    static func csv(_ events: [AuditEventModel]) -> Data {
        var rows = ["id,occurred_at,action,resource_id,outcome,detail"]
        let formatter = ISO8601DateFormatter()
        rows += events.map {
            [
                String($0.id),
                formatter.string(from: $0.occurredAt),
                $0.action,
                $0.resourceID,
                $0.outcome,
                $0.detail,
            ].map(csvField).joined(separator: ",")
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    private static func csvField(_ input: String) -> String {
        let protected: String
        if let first = input.first, "=+-@".contains(first) {
            protected = "'\(input)"
        } else {
            protected = input
        }
        return "\"\(protected.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension JSONEncoder {
    static var aegiz: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var aegizPretty: JSONEncoder {
        let encoder = aegiz
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var aegiz: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
