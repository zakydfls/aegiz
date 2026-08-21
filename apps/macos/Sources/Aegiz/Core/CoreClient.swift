import AegizRPC
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Security

enum CoreClientError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case socketUnavailable
    case protocolMismatch(UInt32)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "Aegiz core is not built. Run `cargo build -p aegiz-core` in the repository."
        case .launchFailed(let message):
            "The local core could not start: \(message)"
        case .socketUnavailable:
            "The local core did not create its private socket in time."
        case .protocolMismatch(let version):
            "Aegiz core protocol \(version) is incompatible with this app (expected \(AegizRPCContract.protocolVersion)). Rebuild the app bundle."
        }
    }
}

actor CoreClient {
    private var process: Process?
    private var bootstrapHandle: FileHandle?
    private var connectionTask: Task<Void, Never>?
    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private var service: Aegiz_V1_AegizCore.Client<HTTP2ClientTransport.Posix>?
    private var sessionToken = ""

    func start() async throws {
        guard process == nil else { return }

        let locations = try applicationLocations()
        let executable = try coreExecutable()
        let token = try randomToken()
        let bootstrap = Pipe()
        let launched = Process()
        launched.executableURL = executable
        launched.arguments = [
            "--socket", locations.socket.path,
            "--database", locations.database.path,
            "--session-stdin",
        ]
        launched.standardInput = bootstrap
        launched.standardOutput = FileHandle.nullDevice
        launched.standardError = FileHandle.nullDevice

        do {
            try launched.run()
        } catch {
            throw CoreClientError.launchFailed(error.localizedDescription)
        }
        process = launched
        sessionToken = token
        bootstrapHandle = bootstrap.fileHandleForWriting
        try bootstrapHandle?.write(contentsOf: Data("\(token)\n".utf8))

        var socketReady = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: locations.socket.path) {
                socketReady = true
                break
            }
            if !launched.isRunning {
                try? bootstrapHandle?.close()
                bootstrapHandle = nil
                process = nil
                throw CoreClientError.launchFailed("the process exited during bootstrap")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard socketReady else {
            launched.terminate()
            try? bootstrapHandle?.close()
            bootstrapHandle = nil
            process = nil
            throw CoreClientError.socketUnavailable
        }

        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(
                path: locations.socket.path,
                authority: "aegiz.local"
            ),
            transportSecurity: .plaintext
        )
        let client = GRPCClient(transport: transport)
        grpcClient = client
        service = Aegiz_V1_AegizCore.Client(wrapping: client)
        connectionTask = Task {
            do {
                try await client.runConnections()
            } catch {
                // The observable model performs health checks and presents recovery.
            }
        }

        var request = Aegiz_V1_HandshakeRequest()
        request.appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let handshake = try await service?.handshake(request, metadata: metadata())
        guard handshake?.protocolVersion == AegizRPCContract.protocolVersion else {
            let version = handshake?.protocolVersion ?? 0
            stop()
            throw CoreClientError.protocolMismatch(version)
        }
    }

    func stop() {
        grpcClient?.beginGracefulShutdown()
        connectionTask?.cancel()
        connectionTask = nil
        grpcClient = nil
        service = nil
        try? bootstrapHandle?.close()
        bootstrapHandle = nil
        if let process, process.isRunning {
            process.interrupt()
        }
        process = nil
        sessionToken = ""
    }

    func dashboard() async throws -> DashboardModel {
        guard let service else { throw CoreClientError.socketUnavailable }
        let value = try await service.getDashboard(
            Aegiz_V1_GetDashboardRequest(),
            metadata: metadata()
        )
        return DashboardModel(
            hosts: Int(value.hostCount),
            tunnels: Int(value.tunnelCount),
            activeTunnels: Int(value.activeTunnelCount),
            attention: Int(value.attentionCount)
        )
    }

    func hosts(query: String = "") async throws -> [HostModel] {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_ListHostsRequest()
        request.query = query
        let response = try await service.listHosts(request, metadata: metadata())
        return response.hosts.map {
            HostModel(
                id: $0.id,
                alias: $0.alias,
                hostname: $0.hostname,
                user: $0.user,
                port: $0.port,
                proxyJump: $0.proxyJump,
                source: $0.source,
                tags: $0.tags
            )
        }
    }

    func importSSHConfig(path: String = "") async throws -> ImportResultModel {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_ImportSSHConfigRequest()
        request.path = path
        let response = try await service.importSSHConfig(request, metadata: metadata())
        return ImportResultModel(
            imported: Int(response.imported),
            updated: Int(response.updated),
            skipped: Int(response.skipped),
            warnings: response.warnings
        )
    }

    func tunnels() async throws -> [TunnelModel] {
        guard let service else { throw CoreClientError.socketUnavailable }
        let response = try await service.listTunnels(
            Aegiz_V1_ListTunnelsRequest(),
            metadata: metadata()
        )
        return response.tunnels.map(Self.mapTunnel)
    }

    func saveTunnel(_ draft: TunnelDraft) async throws -> TunnelModel {
        guard let service else { throw CoreClientError.socketUnavailable }
        var tunnel = Aegiz_V1_Tunnel()
        tunnel.hostID = draft.hostID
        tunnel.label = draft.label
        tunnel.kind = switch draft.kind {
        case .local: .local
        case .remote: .remote
        case .dynamic: .dynamic
        }
        tunnel.bindAddress = draft.bindAddress
        tunnel.localPort = UInt32(draft.localPort) ?? 0
        tunnel.remoteHost = draft.remoteHost
        tunnel.remotePort = UInt32(draft.remotePort) ?? 0
        var request = Aegiz_V1_SaveTunnelRequest()
        request.tunnel = tunnel
        let saved = try await service.saveTunnel(request, metadata: metadata())
        return Self.mapTunnel(saved)
    }

    func setTunnel(
        id: String,
        running: Bool,
        authenticationSecret: Data = Data()
    ) async throws -> String {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_SetTunnelStateRequest()
        request.tunnelID = id
        request.running = running
        request.sshAuthSecret = authenticationSecret
        defer {
            request.sshAuthSecret.resetBytes(in: 0..<request.sshAuthSecret.count)
            request.sshAuthSecret.removeAll(keepingCapacity: false)
        }
        return try await service.setTunnelState(request, metadata: metadata()) { response in
            var finalMessage = ""
            for try await event in response.messages {
                finalMessage = event.message
            }
            return finalMessage
        }
    }

    func capabilities() async throws -> [ToolCapabilityModel] {
        guard let service else { throw CoreClientError.socketUnavailable }
        let response = try await service.listCapabilities(
            Aegiz_V1_ListCapabilitiesRequest(),
            metadata: metadata()
        )
        return response.capabilities.map {
            ToolCapabilityModel(
                id: $0.id,
                label: $0.label,
                available: $0.available,
                executablePath: $0.executablePath,
                version: $0.version,
                diagnostic: $0.diagnostic,
                runnable: $0.runnable
            )
        }
    }

    func runTool(
        adapterID: String,
        arguments: [String],
        workingDirectory: String,
        confirmedMutation: Bool,
        authenticationSecret: Data = Data(),
        onEvent: @escaping @Sendable (OperationEventModel) async -> Void
    ) async throws {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_RunToolRequest()
        request.adapterID = adapterID
        request.arguments = arguments
        request.workingDirectory = workingDirectory
        request.confirmedMutation = confirmedMutation
        request.sshAuthSecret = authenticationSecret
        defer {
            request.sshAuthSecret.resetBytes(in: 0..<request.sshAuthSecret.count)
            request.sshAuthSecret.removeAll(keepingCapacity: false)
        }
        try await service.runTool(request, metadata: metadata()) { response in
            for try await event in response.messages {
                await onEvent(Self.mapOperationEvent(event))
            }
        }
    }

    func cancelOperation(id: String) async throws -> Bool {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_CancelOperationRequest()
        request.operationID = id
        let response = try await service.cancelOperation(request, metadata: metadata())
        return response.accepted
    }

    func auditEvents(limit: UInt32 = 5_000) async throws -> [AuditEventModel] {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_ListAuditEventsRequest()
        request.limit = limit
        let response = try await service.listAuditEvents(request, metadata: metadata())
        let formatter = ISO8601DateFormatter()
        return response.events.map {
            AuditEventModel(
                id: $0.id,
                occurredAt: formatter.date(from: $0.occurredAt) ?? .distantPast,
                action: $0.action,
                resourceID: $0.resourceID,
                outcome: $0.outcome,
                detail: $0.detail
            )
        }
    }

    func databaseProfiles() async throws -> [DatabaseProfileModel] {
        guard let service else { throw CoreClientError.socketUnavailable }
        let response = try await service.listDatabaseProfiles(
            Aegiz_V1_ListDatabaseProfilesRequest(),
            metadata: metadata()
        )
        return response.profiles.map(Self.mapDatabaseProfile)
    }

    func saveDatabaseProfile(_ draft: DatabaseProfileDraft) async throws -> DatabaseProfileModel {
        guard let service else { throw CoreClientError.socketUnavailable }
        var profile = Aegiz_V1_DatabaseProfile()
        profile.id = draft.id
        profile.label = draft.label
        profile.engine = switch draft.engine {
        case .postgres: .postgres
        case .mysql: .mysql
        case .redis: .redis
        }
        profile.hostname = draft.hostname
        profile.port = UInt32(draft.port) ?? 0
        profile.databaseName = draft.databaseName
        profile.username = draft.username
        profile.secretReference = draft.secretReference
        profile.tunnelID = draft.tunnelID
        profile.autoStartTunnel = draft.autoStartTunnel
        profile.readOnly = draft.readOnly
        var request = Aegiz_V1_SaveDatabaseProfileRequest()
        request.profile = profile
        let value = try await service.saveDatabaseProfile(request, metadata: metadata())
        return Self.mapDatabaseProfile(value)
    }

    func deleteDatabaseProfile(id: String) async throws {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_DeleteDatabaseProfileRequest()
        request.profileID = id
        _ = try await service.deleteDatabaseProfile(request, metadata: metadata())
    }

    func runDatabaseQuery(
        profileID: String,
        secret: Data,
        tunnelSSHAuthenticationSecret: Data = Data(),
        sql: String,
        confirmedMutation: Bool,
        onEvent: @escaping @Sendable (OperationEventModel) async -> Void
    ) async throws {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_RunDatabaseQueryRequest()
        request.profileID = profileID
        request.secretValue = secret
        request.tunnelSshAuthSecret = tunnelSSHAuthenticationSecret
        request.sql = sql
        request.confirmedMutation = confirmedMutation
        defer {
            request.secretValue.resetBytes(in: 0..<request.secretValue.count)
            request.secretValue.removeAll(keepingCapacity: false)
            request.tunnelSshAuthSecret.resetBytes(
                in: 0..<request.tunnelSshAuthSecret.count
            )
            request.tunnelSshAuthSecret.removeAll(keepingCapacity: false)
        }
        try await service.runDatabaseQuery(request, metadata: metadata()) { response in
            for try await event in response.messages {
                await onEvent(Self.mapOperationEvent(event))
            }
        }
    }

    func exportBackup() async throws -> Data {
        guard let service else { throw CoreClientError.socketUnavailable }
        var options = CallOptions.defaults
        options.maxResponseMessageBytes = AegizBackupManager.maximumFileSize + 1024
        let response = try await service.exportBackup(
            Aegiz_V1_ExportBackupRequest(),
            metadata: metadata(),
            options: options
        )
        return response.payload
    }

    func restoreBackup(
        _ payload: Data,
        confirmedReplace: Bool
    ) async throws -> BackupRestoreReport {
        guard let service else { throw CoreClientError.socketUnavailable }
        var request = Aegiz_V1_RestoreBackupRequest()
        request.payload = payload
        request.confirmedReplace = confirmedReplace
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = AegizBackupManager.maximumFileSize + 1024
        let response = try await service.restoreBackup(
            request,
            metadata: metadata(),
            options: options
        )
        return BackupRestoreReport(
            hosts: Int(response.hostCount),
            tunnels: Int(response.tunnelCount),
            databaseProfiles: Int(response.databaseProfileCount),
            auditEvents: Int(response.auditEventCount)
        )
    }

    private func metadata() -> Metadata {
        ["x-aegiz-session": .string(sessionToken)]
    }

    private static func mapTunnel(_ value: Aegiz_V1_Tunnel) -> TunnelModel {
        let kind: TunnelKindModel = switch value.kind {
        case .remote: .remote
        case .dynamic: .dynamic
        default: .local
        }
        let status: TunnelStatusModel = switch value.status {
        case .starting: .starting
        case .running: .running
        case .stopping: .stopping
        case .failed: .failed
        default: .stopped
        }
        return TunnelModel(
            id: value.id,
            hostID: value.hostID,
            label: value.label,
            kind: kind,
            bindAddress: value.bindAddress,
            localPort: value.localPort,
            remoteHost: value.remoteHost,
            remotePort: value.remotePort,
            status: status,
            lastError: value.lastError
        )
    }

    private static func mapDatabaseProfile(
        _ value: Aegiz_V1_DatabaseProfile
    ) -> DatabaseProfileModel {
        let engine: DatabaseEngineModel = switch value.engine {
        case .mysql: .mysql
        case .redis: .redis
        default: .postgres
        }
        return DatabaseProfileModel(
            id: value.id,
            label: value.label,
            engine: engine,
            hostname: value.hostname,
            port: value.port,
            databaseName: value.databaseName,
            username: value.username,
            secretReference: value.secretReference,
            tunnelID: value.tunnelID,
            autoStartTunnel: value.autoStartTunnel,
            readOnly: value.readOnly
        )
    }

    private static func mapOperationEvent(
        _ value: Aegiz_V1_OperationEvent
    ) -> OperationEventModel {
        OperationEventModel(
            operationID: value.operationID,
            phase: value.phase,
            message: value.message,
            stream: value.stream,
            sequence: value.sequence,
            progress: value.progress,
            terminal: value.terminal,
            success: value.success,
            exitCode: value.exitCode
        )
    }

    private func applicationLocations() throws -> (socket: URL, database: URL) {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Aegiz", directoryHint: .isDirectory)
        let runtime = try manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Aegiz", directoryHint: .isDirectory)
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        return (
            runtime.appending(path: "core.sock"),
            support.appending(path: "aegiz.sqlite")
        )
    }

    private func coreExecutable() throws -> URL {
        let manager = FileManager.default
        if let bundled = Bundle.main.url(forResource: "aegiz-core", withExtension: nil),
           manager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let explicit = ProcessInfo.processInfo.environment["AEGIZ_CORE_BIN"],
           manager.isExecutableFile(atPath: explicit) {
            return URL(filePath: explicit)
        }

        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in ["target/release/aegiz-core", "target/debug/aegiz-core"] {
            let candidate = repository.appending(path: relative)
            if manager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CoreClientError.executableMissing
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CoreClientError.launchFailed("secure random generation failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
