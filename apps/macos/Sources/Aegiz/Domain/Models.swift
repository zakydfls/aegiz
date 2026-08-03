import Foundation

struct HostModel: Identifiable, Hashable, Sendable {
    let id: String
    var alias: String
    var hostname: String
    var user: String
    var port: UInt32
    var proxyJump: String
    var source: String
    var tags: [String]

    var destination: String {
        user.isEmpty ? hostname : "\(user)@\(hostname)"
    }

    var endpoint: String {
        port == 22 ? destination : "\(destination):\(port)"
    }
}

enum HostSmartFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "All hosts"
    case favorites = "Favorites"
    case production = "Production"
    case staging = "Staging"
    case development = "Development"

    var id: String { rawValue }
}

struct HostOrganizationMetadata: Hashable, Codable, Sendable {
    var workspace = ""
    var company = ""
    var environment = ""
    var tags: [String] = []
    var favorite = false

    func validated() throws -> HostOrganizationMetadata {
        var result = self
        result.workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        result.company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        result.environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = Array(
            Set(
                tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let fields = [result.workspace, result.company, result.environment] + result.tags
        guard result.tags.count <= 32,
              fields.allSatisfy({
                  $0.utf8.count <= 128
                      && !$0.contains("\0")
                      && !$0.contains("\n")
                      && !$0.contains("\r")
              })
        else {
            throw HostOrganizationMetadataError.invalidField
        }
        return result
    }
}

enum HostOrganizationMetadataError: LocalizedError {
    case invalidField

    var errorDescription: String? {
        "Workspace, company, environment, and tags must be short single-line values."
    }
}

struct HostInventoryFilter: Hashable, Codable, Sendable {
    var smart = HostSmartFilter.all
    var workspace = ""
    var company = ""
    var environment = ""
    var tag = ""

    var isScoped: Bool {
        smart != .all
            || !workspace.isEmpty
            || !company.isEmpty
            || !environment.isEmpty
            || !tag.isEmpty
    }
}

struct BackupRestoreReport: Hashable, Sendable {
    let hosts: Int
    let tunnels: Int
    let databaseProfiles: Int
    let auditEvents: Int
}

enum AuditExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv

    var id: String { rawValue }
}

struct TerminalSessionModel: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var hostID: String
    var hostAlias: String
    var endpoint: String
    var createdAt: Date
    var generation: UUID
    var localExecutable: String?
    var localArguments: [String]?

    init(host: HostModel) {
        id = UUID()
        hostID = host.id
        hostAlias = host.alias
        endpoint = host.endpoint
        createdAt = Date()
        generation = UUID()
        localExecutable = nil
        localArguments = nil
    }

    init(
        localTitle: String,
        endpoint: String,
        executable: String,
        arguments: [String]
    ) {
        id = UUID()
        hostID = ""
        hostAlias = localTitle
        self.endpoint = endpoint
        createdAt = Date()
        generation = UUID()
        localExecutable = executable
        localArguments = arguments
    }

    var isLocalProcess: Bool { localExecutable != nil }
}

struct TerminalEnvironmentVariable: Identifiable, Hashable, Codable, Sendable {
    var id: String { name }
    var name: String
    var value: String
}

struct TerminalHostSettings: Hashable, Codable, Sendable {
    var localWorkingDirectory = ""
    var remoteWorkingDirectory = ""
    var environment: [TerminalEnvironmentVariable] = []
    var fontSize: Double = 0
    var startupCommand = ""

    var environmentText: String {
        environment.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")
    }

    func validated() throws -> TerminalHostSettings {
        var result = self
        result.localWorkingDirectory = localWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.remoteWorkingDirectory = remoteWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.startupCommand = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if !result.localWorkingDirectory.isEmpty {
            guard result.localWorkingDirectory.hasPrefix("/"),
                  !result.localWorkingDirectory.contains("\n"),
                  !result.localWorkingDirectory.contains("\0")
            else {
                throw TerminalSettingsError.invalidLocalWorkingDirectory
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: result.localWorkingDirectory,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw TerminalSettingsError.localWorkingDirectoryNotFound
            }
        }
        guard !result.remoteWorkingDirectory.contains("\n"),
              !result.remoteWorkingDirectory.contains("\0")
        else {
            throw TerminalSettingsError.invalidRemoteWorkingDirectory
        }
        guard !result.startupCommand.contains("\0"),
              result.startupCommand.utf8.count <= 16_384
        else {
            throw TerminalSettingsError.invalidStartupCommand
        }
        guard result.fontSize == 0 || (8...32).contains(result.fontSize) else {
            throw TerminalSettingsError.invalidFontSize
        }
        guard result.environment.count <= 64 else {
            throw TerminalSettingsError.tooManyEnvironmentVariables
        }
        var seen: Set<String> = []
        for variable in result.environment {
            guard Self.isValidEnvironmentName(variable.name),
                  !variable.value.contains("\0"),
                  variable.value.utf8.count <= 8_192,
                  seen.insert(variable.name).inserted
            else {
                throw TerminalSettingsError.invalidEnvironmentVariable(variable.name)
            }
        }
        return result
    }

    static func parseEnvironment(_ text: String) throws -> [TerminalEnvironmentVariable] {
        var result: [TerminalEnvironmentVariable] = []
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw TerminalSettingsError.invalidEnvironmentVariable(line)
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            guard isValidEnvironmentName(name) else {
                throw TerminalSettingsError.invalidEnvironmentVariable(name)
            }
            result.append(TerminalEnvironmentVariable(name: name, value: value))
        }
        return result
    }

    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
        else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}

enum TerminalSettingsError: LocalizedError, Equatable {
    case invalidLocalWorkingDirectory
    case localWorkingDirectoryNotFound
    case invalidRemoteWorkingDirectory
    case invalidStartupCommand
    case invalidFontSize
    case tooManyEnvironmentVariables
    case invalidEnvironmentVariable(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocalWorkingDirectory:
            "The local working directory must be an absolute path without control characters."
        case .localWorkingDirectoryNotFound:
            "The local working directory does not exist or is not a directory."
        case .invalidRemoteWorkingDirectory:
            "The remote working directory cannot contain line breaks or null bytes."
        case .invalidStartupCommand:
            "The startup command is too large or contains a null byte."
        case .invalidFontSize:
            "Font size must be between 8 and 32 points, or 0 to inherit Ghostty settings."
        case .tooManyEnvironmentVariables:
            "A session can define at most 64 environment variables."
        case .invalidEnvironmentVariable(let name):
            "Invalid or duplicate environment variable: \(name.isEmpty ? "(empty)" : name)."
        }
    }
}

struct TerminalLaunchConfiguration: Hashable, Sendable {
    let hostAlias: String
    let command: String
    let validatesSSHHostAlias: Bool
    let localWorkingDirectory: String
    let environment: [TerminalEnvironmentVariable]
    let fontSize: Double
    let initialInput: String

    init(hostAlias: String, settings: TerminalHostSettings) {
        self.hostAlias = hostAlias
        command = [
            "/usr/bin/ssh",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            hostAlias,
        ].joined(separator: " ")
        validatesSSHHostAlias = true
        localWorkingDirectory = settings.localWorkingDirectory
        environment = AegizProcessEnvironment.addingExecutableSearchPath(
            to: settings.environment
        )
        fontSize = settings.fontSize

        var startup: [String] = []
        if !settings.remoteWorkingDirectory.isEmpty {
            startup.append(
                "cd -- \(RemoteShellEscaping.singleQuoted(settings.remoteWorkingDirectory))"
            )
        }
        if !settings.startupCommand.isEmpty {
            startup.append(settings.startupCommand)
        }
        initialInput = startup.isEmpty ? "" : startup.joined(separator: " && ") + "\n"
    }

    init(
        title: String,
        executable: String,
        arguments: [String]
    ) {
        hostAlias = title
        command = TerminalLocalCommand.encoded(executable: executable, arguments: arguments) ?? ""
        validatesSSHHostAlias = false
        localWorkingDirectory = ""
        environment = AegizProcessEnvironment.addingExecutableSearchPath(to: [])
        fontSize = 0
        initialInput = ""
    }
}

enum AegizProcessEnvironment {
    static let executableSearchPath: String = {
        let preferred = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen: Set<String> = []
        return (preferred + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }()

    static func addingExecutableSearchPath(
        to environment: [TerminalEnvironmentVariable]
    ) -> [TerminalEnvironmentVariable] {
        guard !environment.contains(where: { $0.name == "PATH" }) else {
            return environment
        }
        return environment + [
            TerminalEnvironmentVariable(name: "PATH", value: executableSearchPath)
        ]
    }
}

enum RemoteShellEscaping {
    static func singleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

enum TerminalLocalCommand {
    private static let allowedNames: Set<String> = [
        "aws", "docker", "kubectl",
    ]
    private static let allowedDirectories: Set<String> = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
    ]

    static func encoded(executable: String, arguments: [String]) -> String? {
        let url = URL(filePath: executable)
        guard url.path == executable,
              executable.hasPrefix("/"),
              allowedNames.contains(url.lastPathComponent),
              allowedDirectories.contains(url.deletingLastPathComponent().path),
              arguments.count <= 128,
              arguments.map(\.utf8.count).reduce(0, +) <= 32 * 1024,
              arguments.allSatisfy({
                  !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
              })
        else {
            return nil
        }
        return ([executable] + arguments)
            .map(RemoteShellEscaping.singleQuoted)
            .joined(separator: " ")
    }
}

struct SFTPEntryModel: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let permissions: String
    let owner: String
    let group: String
    let size: Int64?
    let modified: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

enum DatabaseEngineModel: String, CaseIterable, Identifiable, Sendable {
    case postgres = "PostgreSQL"
    case mysql = "MySQL"
    case redis = "Redis"

    var id: String { rawValue }
    var defaultPort: String {
        switch self {
        case .postgres: "5432"
        case .mysql: "3306"
        case .redis: "6379"
        }
    }
}

struct DatabaseProfileModel: Identifiable, Hashable, Sendable {
    let id: String
    var label: String
    var engine: DatabaseEngineModel
    var hostname: String
    var port: UInt32
    var databaseName: String
    var username: String
    var secretReference: String
    var tunnelID: String
    var autoStartTunnel: Bool
    var readOnly: Bool

    var endpoint: String {
        "\(hostname):\(port)"
    }
}

struct DatabaseProfileDraft {
    var id = ""
    var label = ""
    var engine = DatabaseEngineModel.postgres
    var hostname = "127.0.0.1"
    var port = "5432"
    var databaseName = ""
    var username = ""
    var secretReference = ""
    var tunnelID = ""
    var autoStartTunnel = false
    var readOnly = true
}

enum DatabaseQueryRisk {
    static func isReadOnly(
        _ sql: String,
        engine: DatabaseEngineModel = .postgres
    ) -> Bool {
        let normalized = sql
            .drop(while: { $0.isWhitespace || $0 == ";" })
            .lowercased()
        if engine == .redis {
            return [
                "scan", "get", "mget", "type", "ttl", "pttl", "exists", "strlen",
                "hget", "hgetall", "hlen", "lrange", "llen", "smembers", "scard",
                "zrange", "zcard", "info", "dbsize", "ping", "echo",
            ].contains {
                normalized == $0
                    || normalized.hasPrefix("\($0) ")
                || normalized.hasPrefix("\($0)\n")
            }
        }
        if let separator = normalized.firstIndex(of: ";"),
           normalized[normalized.index(after: separator)...].contains(where: {
               !$0.isWhitespace && $0 != ";"
           }) {
            return false
        }
        return ["select", "show", "explain", "describe", "desc", "values"].contains {
            normalized == $0
                || normalized.hasPrefix("\($0) ")
                || normalized.hasPrefix("\($0)\n")
        }
    }
}

enum RedisCommandEscaping {
    static func quoted(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= 16_384,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r")
        else {
            return nil
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum DatabaseQueryHistory {
    static func redactedSummary(_ query: String) -> String {
        var result = query.replacingOccurrences(
            of: #"'(?:''|[^'])*'"#,
            with: "'…'",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(password|passwd|token|secret|access[_-]?key)\s*[:=]\s*[^\s,;]+"#,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        result = result
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(result.prefix(80))
    }
}

enum SFTPListingParser {
    static func parse(_ output: String, directory: String) -> [SFTPEntryModel] {
        let parsed: [SFTPEntryModel] = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(
                    maxSplits: 8,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard fields.count == 9 else { return nil }
                let permissions = String(fields[0])
                guard let type = permissions.first, "-dl".contains(type) else { return nil }
                var name = String(fields[8])
                if type == "l", let range = name.range(of: " -> ") {
                    name = String(name[..<range.lowerBound])
                }
                // Some SFTP servers echo the requested directory in every
                // long-listing entry (for example ./deployment/api). Display
                // and append only the leaf to avoid duplicated remote paths.
                name = (name as NSString).lastPathComponent
                guard name != ".", name != ".." else { return nil }
                return SFTPEntryModel(
                    name: name,
                    path: remotePath(directory, appending: name),
                    permissions: permissions,
                    owner: String(fields[2]),
                    group: String(fields[3]),
                    size: Int64(fields[4]),
                    modified: fields[5...7].joined(separator: " "),
                    isDirectory: type == "d",
                    isSymbolicLink: type == "l"
                )
            }
        var paths = Set<String>()
        return parsed
            .filter { paths.insert($0.path).inserted }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func remotePath(_ directory: String, appending name: String) -> String {
        if directory == "/" { return "/\(name)" }
        if directory == "." { return name }
        return "\(directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(name)"
            .withLeadingSlash(if: directory.hasPrefix("/"))
    }
}

struct FileTextPreviewDocument: Equatable, Sendable {
    let text: String
    let encoding: String
    let byteCount: Int
    let usedLossyDecoding: Bool

    var containsOnlyWhitespace: Bool {
        !text.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum FileTextPreviewError: Error, Equatable {
    case tooLarge(limit: Int)
    case binary
}

enum FileTextPreviewDecoder {
    static let maximumBytes = 1_048_576

    static func decode(
        _ data: Data,
        maximumBytes: Int = maximumBytes
    ) throws -> FileTextPreviewDocument {
        guard data.count <= maximumBytes else {
            throw FileTextPreviewError.tooLarge(limit: maximumBytes)
        }
        guard !data.isEmpty else {
            return FileTextPreviewDocument(
                text: "",
                encoding: "Empty",
                byteCount: 0,
                usedLossyDecoding: false
            )
        }

        if let decoded = decodeByteOrderMarked(data) {
            return document(decoded.text, encoding: decoded.encoding, data: data, lossy: false)
        }
        if let decoded = decodeUnmarkedUnicode(data) {
            return document(decoded.text, encoding: decoded.encoding, data: data, lossy: false)
        }
        guard !looksBinary(data) else {
            throw FileTextPreviewError.binary
        }
        if let value = String(data: data, encoding: .utf8) {
            return document(value, encoding: "UTF-8", data: data, lossy: false)
        }
        if let value = String(data: data, encoding: .windowsCP1252) {
            return document(value, encoding: "Windows-1252", data: data, lossy: false)
        }
        if let value = String(data: data, encoding: .isoLatin1) {
            return document(value, encoding: "ISO-8859-1", data: data, lossy: false)
        }
        return document(
            String(decoding: data, as: UTF8.self),
            encoding: "UTF-8 with replacements",
            data: data,
            lossy: true
        )
    }

    private static func decodeByteOrderMarked(_ data: Data) -> (text: String, encoding: String)? {
        let bytes = [UInt8](data.prefix(4))
        let candidates: [([UInt8], String.Encoding, String)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian, "UTF-32 BE"),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian, "UTF-32 LE"),
            ([0xEF, 0xBB, 0xBF], .utf8, "UTF-8"),
            ([0xFE, 0xFF], .utf16BigEndian, "UTF-16 BE"),
            ([0xFF, 0xFE], .utf16LittleEndian, "UTF-16 LE"),
        ]
        for (marker, encoding, name) in candidates where bytes.starts(with: marker) {
            guard let value = String(data: data, encoding: encoding) else { return nil }
            return (value.removingLeadingByteOrderMark(), name)
        }
        return nil
    }

    private static func decodeUnmarkedUnicode(_ data: Data) -> (text: String, encoding: String)? {
        let sample = [UInt8](data.prefix(4_096))
        guard sample.count >= 4, sample.count.isMultiple(of: 2) else { return nil }
        let pairCount = sample.count / 2
        let evenZeroRatio = Double(stride(from: 0, to: sample.count, by: 2).filter {
            sample[$0] == 0
        }.count) / Double(pairCount)
        let oddZeroRatio = Double(stride(from: 1, to: sample.count, by: 2).filter {
            sample[$0] == 0
        }.count) / Double(pairCount)
        if oddZeroRatio > 0.30, evenZeroRatio < 0.10,
           let value = String(data: data, encoding: .utf16LittleEndian) {
            return (value, "UTF-16 LE")
        }
        if evenZeroRatio > 0.30, oddZeroRatio < 0.10,
           let value = String(data: data, encoding: .utf16BigEndian) {
            return (value, "UTF-16 BE")
        }
        return nil
    }

    private static func looksBinary(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(8_192))
        let binaryMagic: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47],
            [0xFF, 0xD8, 0xFF],
            [0x47, 0x49, 0x46, 0x38],
            [0x25, 0x50, 0x44, 0x46],
            [0x50, 0x4B, 0x03, 0x04],
            [0x1F, 0x8B],
            [0x7F, 0x45, 0x4C, 0x46],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
        ]
        if binaryMagic.contains(where: { sample.starts(with: $0) }) || sample.contains(0) {
            return true
        }
        let controls = sample.filter { byte in
            (byte < 0x20 && ![0x09, 0x0A, 0x0D].contains(byte)) || byte == 0x7F
        }.count
        return controls * 50 > sample.count
    }

    private static func document(
        _ text: String,
        encoding: String,
        data: Data,
        lossy: Bool
    ) -> FileTextPreviewDocument {
        FileTextPreviewDocument(
            text: sanitize(text.removingLeadingByteOrderMark()),
            encoding: encoding,
            byteCount: data.count,
            usedLossyDecoding: lossy
        )
    }

    private static func sanitize(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if (code < 0x20 && ![0x09, 0x0A, 0x0D].contains(code)) || code == 0x7F {
                output.append("\u{FFFD}")
            } else {
                output.append(Character(scalar))
            }
        }
        return output
    }
}

private extension String {
    func withLeadingSlash(if condition: Bool) -> String {
        condition && !hasPrefix("/") ? "/\(self)" : self
    }

    func removingLeadingByteOrderMark() -> String {
        unicodeScalars.first?.value == 0xFEFF ? String(dropFirst()) : self
    }
}

enum TerminalSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

enum TerminalSessionLifecycle {
    static func removing(
        _ id: UUID,
        from sessions: [TerminalSessionModel]
    ) -> [TerminalSessionModel] {
        sessions.filter { $0.id != id }
    }
}

enum TunnelKindModel: String, CaseIterable, Identifiable, Sendable {
    case local = "Local"
    case remote = "Remote"
    case dynamic = "SOCKS"

    var id: String { rawValue }
}

enum TunnelStatusModel: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case failed = "Failed"

    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .stopping: "clock.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .stopped: "stop.circle"
        }
    }
}

struct TunnelModel: Identifiable, Hashable, Sendable {
    let id: String
    var hostID: String
    var label: String
    var kind: TunnelKindModel
    var bindAddress: String
    var localPort: UInt32
    var remoteHost: String
    var remotePort: UInt32
    var status: TunnelStatusModel
    var lastError: String

    var localEndpointKey: String? {
        guard kind != .remote else { return nil }
        return "\(bindAddress.lowercased()):\(localPort)"
    }

    var route: String {
        switch kind {
        case .local, .remote:
            "\(bindAddress):\(localPort) → \(remoteHost):\(remotePort)"
        case .dynamic:
            "\(bindAddress):\(localPort) SOCKS5"
        }
    }

    func route(via sshHostAlias: String) -> String {
        switch kind {
        case .local:
            "Mac \(bindAddress):\(localPort) → SSH \(sshHostAlias) → remote \(remoteHost):\(remotePort)"
        case .remote:
            "SSH \(sshHostAlias) \(bindAddress):\(localPort) → Mac-side \(remoteHost):\(remotePort)"
        case .dynamic:
            "Mac \(bindAddress):\(localPort) SOCKS5 → SSH \(sshHostAlias)"
        }
    }
}

struct DashboardModel: Sendable {
    var hosts = 0
    var tunnels = 0
    var activeTunnels = 0
    var attention = 0
}

struct ImportResultModel: Sendable {
    let imported: Int
    let updated: Int
    let skipped: Int
    let warnings: [String]
}

struct TunnelDraft {
    var hostID = ""
    var label = ""
    var kind = TunnelKindModel.local
    var bindAddress = "127.0.0.1"
    var localPort = "5433"
    var remoteHost = "127.0.0.1"
    var remotePort = "5432"
    var secretReference = ""
}

struct ToolCapabilityModel: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let available: Bool
    let executablePath: String
    let version: String
    let diagnostic: String
    let runnable: Bool
}

struct OperationEventModel: Sendable {
    let operationID: String
    let phase: String
    let message: String
    let stream: String
    let sequence: UInt64
    let progress: UInt32
    let terminal: Bool
    let success: Bool
    let exitCode: Int32
}

struct ToolOperationModel: Sendable {
    var id = ""
    var adapterID: String
    var title: String
    var phase = "queued"
    var output = ""
    var progress: UInt32 = 0
    var isRunning = true
    var success: Bool?
    var exitCode: Int32?

    mutating func consume(_ event: OperationEventModel) {
        if !event.operationID.isEmpty {
            id = event.operationID
        }
        phase = event.phase
        progress = event.progress
        if event.stream == "stdout" || event.stream == "stderr" {
            output.append(event.message)
            if output.utf8.count > 1_000_000 {
                output = String(output.suffix(750_000))
            }
        } else if !event.message.isEmpty {
            if !output.isEmpty, !output.hasSuffix("\n") {
                output.append("\n")
            }
            output.append("› \(event.message)\n")
        }
        if event.terminal {
            isRunning = false
            success = event.success
            exitCode = event.exitCode
        }
    }
}

struct AuditEventModel: Identifiable, Hashable, Sendable {
    let id: Int64
    let occurredAt: Date
    let action: String
    let resourceID: String
    let outcome: String
    let detail: String
}

struct ToolPreset: Identifiable, Hashable, Sendable {
    let title: String
    let arguments: String

    var id: String { "\(title):\(arguments)" }
}

enum CommandLineTokenizerError: LocalizedError {
    case unfinishedQuote
    case trailingEscape

    var errorDescription: String? {
        switch self {
        case .unfinishedQuote:
            "The command has an unfinished quote."
        case .trailingEscape:
            "The command ends with an unfinished escape."
        }
    }
}

enum CommandLineTokenizer {
    static func parse(_ input: String) throws -> [String] {
        enum Mode {
            case normal
            case singleQuote
            case doubleQuote
        }

        var mode = Mode.normal
        var escaping = false
        var current = ""
        var arguments: [String] = []
        var tokenStarted = false

        for character in input {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }
            switch mode {
            case .normal:
                switch character {
                case "\\":
                    escaping = true
                    tokenStarted = true
                case "'":
                    mode = .singleQuote
                    tokenStarted = true
                case "\"":
                    mode = .doubleQuote
                    tokenStarted = true
                case " ", "\t":
                    if tokenStarted {
                        arguments.append(current)
                        current = ""
                        tokenStarted = false
                    }
                default:
                    current.append(character)
                    tokenStarted = true
                }
            case .singleQuote:
                if character == "'" {
                    mode = .normal
                } else {
                    current.append(character)
                }
            case .doubleQuote:
                if character == "\"" {
                    mode = .normal
                } else if character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                }
            }
        }
        if escaping {
            throw CommandLineTokenizerError.trailingEscape
        }
        guard mode == .normal else {
            throw CommandLineTokenizerError.unfinishedQuote
        }
        if tokenStarted {
            arguments.append(current)
        }
        return arguments
    }
}

enum ToolCommandRisk {
    static func requiresConfirmation(adapterID: String, arguments: [String]) -> Bool {
        if adapterID == "ssh-host" {
            guard arguments.count == 8 else { return true }
            return !HostRemoteCommandRisk.isKnownReadOnly(arguments[7])
        }
        if adapterID == "sftp" {
            return arguments.count < 2 || arguments[1] != "list"
        }
        return switch adapterID {
        case "docker":
            dockerRequiresConfirmation(arguments)
        case "kubectl":
            classify(
                arguments,
                mutations: [
                    "annotate", "apply", "attach", "autoscale", "certificate", "cordon", "cp",
                    "create", "delete", "drain", "edit", "exec", "expose", "label", "patch",
                    "port-forward", "replace", "rollout", "run", "scale", "set", "taint",
                    "uncordon",
                ],
                reads: [
                    "api-resources", "api-versions", "auth", "cluster-info", "config",
                    "describe", "diff", "explain", "get", "help", "logs", "options", "top",
                    "version", "wait",
                ]
            )
        case "aws":
            awsRequiresConfirmation(arguments)
        case "terraform":
            classify(
                arguments,
                mutations: [
                    "apply", "destroy", "force-unlock", "import", "login", "logout",
                    "refresh", "state", "taint", "untaint", "workspace",
                ],
                reads: [
                    "console", "fmt", "get", "graph", "help", "output", "plan",
                    "providers", "show", "validate", "version",
                ]
            )
        case "ansible", "ansible-playbook":
            !arguments.contains("--check")
                && !arguments.contains("--help")
                && !arguments.contains("--version")
        case "ansible-inventory":
            false
        default:
            true
        }
    }

    private static func classify(
        _ arguments: [String],
        mutations: Set<String>,
        reads: Set<String>
    ) -> Bool {
        if arguments.contains(where: mutations.contains) {
            return true
        }
        return !arguments.contains(where: reads.contains)
    }

    private static func dockerRequiresConfirmation(_ arguments: [String]) -> Bool {
        let optionsWithValues: Set<String> = [
            "--config", "--context", "--host", "-H", "--log-level",
        ]
        var positionals: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
            } else if optionsWithValues.contains(argument) {
                skipNext = true
            } else if !argument.hasPrefix("-") {
                positionals.append(argument)
            }
        }
        guard let command = positionals.first else { return false }
        if command == "compose" {
            guard positionals.count > 1 else { return true }
            return ![
                "config", "events", "images", "logs", "ls", "port", "ps", "top", "version",
                "wait",
            ].contains(positionals[1])
        }
        if command == "context" {
            guard positionals.count > 1 else { return true }
            return !["inspect", "ls", "show"].contains(positionals[1])
        }
        return ![
            "events", "help", "history", "images", "info", "inspect", "logs", "ps", "stats",
            "system", "top", "version",
        ].contains(command)
    }

    private static func awsRequiresConfirmation(_ arguments: [String]) -> Bool {
        let optionsWithValues: Set<String> = [
            "--ca-bundle", "--cli-connect-timeout", "--cli-read-timeout", "--color",
            "--endpoint-url", "--output", "--profile", "--query", "--region",
        ]
        var positional: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
            } else if optionsWithValues.contains(argument) {
                skipNext = true
            } else if !argument.hasPrefix("-") {
                positional.append(argument)
            }
        }
        guard positional.count > 1 else { return false }
        let operation = positional[1]
        return ![
            "batch-get", "describe", "filter", "get", "head", "list", "lookup", "search",
            "select", "simulate", "tail",
        ].contains { operation == $0 || operation.hasPrefix("\($0)-") }
    }
}

enum HostRemoteCommandRisk {
    static let processListCommand =
        "ps -axo pid=,ppid=,user=,%cpu=,%mem=,etime=,comm=,args="
    static let serviceListCommand =
        "systemctl list-units --type=service --state=running --no-pager --no-legend"
    static let factsCommand = """
    printf 'OS: '; (grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || uname -s); printf 'Kernel: '; uname -sr; printf 'Uptime: '; uptime; printf '\\nFilesystems:\\n'; df -hP; printf '\\nMemory:\\n'; (free -h 2>/dev/null || vm_stat 2>/dev/null || true); printf '\\nAddresses:\\n'; (hostname -I 2>/dev/null || ifconfig 2>/dev/null | awk '/inet / {print $2}')
    """
    .trimmingCharacters(in: .whitespacesAndNewlines)

    static func isKnownReadOnly(_ rawCommand: String) -> Bool {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if [
            "true",
            "uptime",
            processListCommand,
            serviceListCommand,
            factsCommand,
            "journalctl --no-pager -n 300",
            "journalctl --no-pager -f -n 200",
        ].contains(command) {
            return true
        }
        if command.hasPrefix("journalctl --no-pager -n 300 -u ") {
            return isSafeUnit(String(command.dropFirst("journalctl --no-pager -n 300 -u ".count)))
        }
        if command.hasPrefix("journalctl --no-pager -f -n 200 -u ") {
            return isSafeUnit(
                String(command.dropFirst("journalctl --no-pager -f -n 200 -u ".count))
            )
        }
        let tailPrefix = "tail -n 200 -F -- '"
        guard command.hasPrefix(tailPrefix), command.hasSuffix("'") else {
            return false
        }
        let path = command.dropFirst(tailPrefix.count).dropLast()
        return path.hasPrefix("/")
            && !path.isEmpty
            && !path.contains("'")
            && !path.contains("\0")
            && !path.contains("\n")
            && !path.contains("\r")
    }

    static func isSafeUnit(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "@_.:-".unicodeScalars.contains($0)
        }
    }
}

enum HostOperationFailureClassifier {
    static func message(for output: String) -> String? {
        let value = output.lowercased()
        if value.contains("host key verification failed")
            || value.contains("remote host identification has changed") {
            return "Host key verification failed. Review the fingerprint in known_hosts before making any change."
        }
        if value.contains("permission denied") {
            return "Authentication failed. Check the selected SSH config identity, agent, or server authorization."
        }
        if value.contains("could not resolve hostname") || value.contains("name or service not known") {
            return "DNS resolution failed for this SSH alias or its configured hostname."
        }
        if value.contains("connection timed out") || value.contains("operation timed out") {
            return "The connection timed out. Check routing, VPN, firewall, and the SSH port."
        }
        if value.contains("connection refused") {
            return "The target refused the connection. SSH may be stopped or listening on another port."
        }
        if value.contains("no route to host") || value.contains("network is unreachable") {
            return "No network route is available. Check VPN, gateway, and ProxyJump connectivity."
        }
        return nil
    }
}

enum SecretKindModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case generic = "Generic"
    case password = "Password"
    case sshPassword = "SSH Password"
    case database = "Database"
    case apiToken = "API Token"
    case cloud = "Cloud"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .generic: "key.fill"
        case .password: "lock.fill"
        case .sshPassword: "lock.shield.fill"
        case .database: "cylinder.fill"
        case .apiToken: "number.square.fill"
        case .cloud: "cloud.fill"
        }
    }
}

struct SecretMetadataModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: SecretKindModel
    let requiresUserPresence: Bool
    let createdAt: Date
    let modifiedAt: Date
}

struct SecretDraft: Sendable {
    var name = ""
    var kind = SecretKindModel.generic
    var value = ""
    var requiresUserPresence = true
}
