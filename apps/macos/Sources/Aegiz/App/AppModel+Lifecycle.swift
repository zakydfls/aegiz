import Foundation

@MainActor
extension AppModel {
    // MARK: - Core lifecycle and inventory refresh

    func start() async {
        await refreshVault()
        connectionState = .connecting
        do {
            try await core.start()
            connectionState = .online
            await refresh()
        } catch {
            connectionState = .unavailable(String(describing: error))
        }
    }

    func retry() async {
        await core.stop()
        await start()
    }

    func shutdown() {
        lockVault()
        Task { await core.stop() }
    }

    func refresh() async {
        guard connectionState == .online else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            async let nextHosts = core.hosts()
            async let nextTunnels = core.tunnels()
            async let nextDashboard = core.dashboard()
            async let nextCapabilities = core.capabilities()
            async let nextAuditEvents = core.auditEvents()
            async let nextDatabaseProfiles = core.databaseProfiles()
            let (hosts, tunnels, dashboard, capabilities, auditEvents, databaseProfiles) = try await (
                nextHosts,
                nextTunnels,
                nextDashboard,
                nextCapabilities,
                nextAuditEvents,
                nextDatabaseProfiles
            )
            self.hosts = hosts
            self.tunnels = tunnels
            self.dashboard = dashboard
            self.capabilities = capabilities
            self.auditEvents = auditEvents
            self.databaseProfiles = databaseProfiles
            if selectedHostID == nil || !hosts.contains(where: { $0.id == selectedHostID }) {
                selectedHostID = hosts.first?.id
            }
            if selectedTunnelID == nil || !tunnels.contains(where: { $0.id == selectedTunnelID }) {
                selectedTunnelID = tunnels.first?.id
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func importSSHConfig() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await core.importSSHConfig()
            notice = "SSH config: \(result.imported) imported, \(result.updated) updated, \(result.skipped) patterns skipped."
            await refresh()
        } catch {
            notice = error.localizedDescription
        }
    }
}
