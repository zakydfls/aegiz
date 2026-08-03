import SwiftUI

struct CommandCenterView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if case .unavailable(let message) = model.connectionState {
                unavailable(message)
            } else if model.hosts.isEmpty && !model.isBusy {
                firstRun
            } else {
                hostTable
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle("Command Center")
    }

    private var header: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    metric("Hosts", value: model.dashboard.hosts, symbol: "server.rack")
                    Divider().frame(height: 30).padding(.horizontal, 16)
                    metric("Tunnels", value: model.dashboard.activeTunnels, symbol: "point.3.connected.trianglepath.dotted")
                    Divider().frame(height: 30).padding(.horizontal, 16)
                    metric("Attention", value: model.dashboard.attention, symbol: "exclamationmark.triangle")
                    Spacer()
                    importButton
                }
                HStack(spacing: 14) {
                    compactMetric(value: model.dashboard.hosts, symbol: "server.rack", help: "Hosts")
                    compactMetric(
                        value: model.dashboard.activeTunnels,
                        symbol: "point.3.connected.trianglepath.dotted",
                        help: "Active tunnels"
                    )
                    compactMetric(
                        value: model.dashboard.attention,
                        symbol: "exclamationmark.triangle",
                        help: "Needs attention"
                    )
                    Spacer()
                    importButton.labelStyle(.iconOnly)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            inventoryFilters
        }
    }

    private var inventoryFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                inventorySearch
                smartFilter
                scopePicker(
                    "Workspace",
                    values: model.workspaceNames,
                    selection: $model.hostInventoryFilter.workspace
                )
                scopePicker(
                    "Company",
                    values: model.companyNames,
                    selection: $model.hostInventoryFilter.company
                )
                scopePicker(
                    "Environment",
                    values: model.environmentNames,
                    selection: $model.hostInventoryFilter.environment
                )
                scopePicker(
                    "Tag",
                    values: model.organizationTags,
                    selection: $model.hostInventoryFilter.tag
                )
                clearFilters
                Spacer()
                visibleCount
            }
            HStack(spacing: 8) {
                inventorySearch
                smartFilter
                Menu {
                    scopeMenu(
                        "Workspace",
                        values: model.workspaceNames,
                        selection: $model.hostInventoryFilter.workspace
                    )
                    scopeMenu(
                        "Company",
                        values: model.companyNames,
                        selection: $model.hostInventoryFilter.company
                    )
                    scopeMenu(
                        "Environment",
                        values: model.environmentNames,
                        selection: $model.hostInventoryFilter.environment
                    )
                    scopeMenu(
                        "Tag",
                        values: model.organizationTags,
                        selection: $model.hostInventoryFilter.tag
                    )
                } label: {
                    Label("Scope", systemImage: "line.3.horizontal.decrease.circle")
                }
                clearFilters
                Spacer()
                visibleCount
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(AegizTheme.canvas.opacity(0.5))
    }

    private var inventorySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search hosts", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search hosts, tags, and addresses")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .aegizIconAction("Clear host search")
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250, minHeight: 28)
        .background(AegizTheme.raised, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(AegizTheme.subtleBorder, lineWidth: 1)
        }
    }

    private var smartFilter: some View {
        Picker("Smart filter", selection: $model.hostInventoryFilter.smart) {
            ForEach(HostSmartFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .labelsHidden()
        .frame(width: 132)
    }

    @ViewBuilder
    private var clearFilters: some View {
        if model.hostInventoryFilter.isScoped {
            Button("Clear") { model.clearInventoryScope() }
                .buttonStyle(.borderless)
                .help("Clear all inventory filters")
        }
    }

    private var visibleCount: some View {
        Text("\(model.visibleHosts.count) visible")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var importButton: some View {
        Button {
            Task { await model.importSSHConfig() }
        } label: {
            Label("Import SSH Config", systemImage: "square.and.arrow.down")
        }
        .disabled(model.connectionState != .online || model.isBusy)
        .help("Import or refresh hosts from your OpenSSH config")
    }

    private func compactMetric(value: Int, symbol: String, help: String) -> some View {
        Label {
            Text(value, format: .number)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private func scopeMenu(
        _ label: String,
        values: [String],
        selection: Binding<String>
    ) -> some View {
        Menu(label) {
            Button("Any \(label.lowercased())") { selection.wrappedValue = "" }
            if !values.isEmpty { Divider() }
            ForEach(values, id: \.self) { value in
                Button {
                    selection.wrappedValue = value
                } label: {
                    if selection.wrappedValue == value {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        }
    }

    private func scopePicker(
        _ label: String,
        values: [String],
        selection: Binding<String>
    ) -> some View {
        Picker(label, selection: selection) {
            Text("Any \(label.lowercased())").tag("")
            ForEach(values, id: \.self) { value in
                Text(value).tag(value)
            }
        }
        .labelsHidden()
        .frame(width: 138)
    }

    private func metric(_ label: String, value: Int, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var hostTable: some View {
        Table(model.visibleHosts, selection: $model.selectedHostID) {
            TableColumn("Host") { host in
                hostCell(host) {
                    HStack(spacing: 8) {
                    Image(
                        systemName: model.hostOrganization(for: host.id).favorite
                            ? "star.fill" : "server.rack"
                    )
                    .foregroundStyle(
                        model.hostOrganization(for: host.id).favorite ? .yellow : AegizTheme.accent
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.alias)
                            .font(.system(size: 12, weight: .medium))
                        Text(host.hostname)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    }
                    .padding(.vertical, 3)
                }
                .contextMenu {
                    Button("Open SSH Session") { model.openSession(host) }
                    Divider()
                    Text(host.source)
                }
            }
            .width(min: 190, ideal: 230)

            TableColumn("User") { host in
                hostCell(host) {
                    Text(host.user.isEmpty ? "Default" : host.user)
                        .foregroundStyle(host.user.isEmpty ? .secondary : .primary)
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Port") { host in
                hostCell(host) {
                    Text(host.port, format: .number)
                        .monospacedDigit()
                }
            }
            .width(54)

            TableColumn("Route") { host in
                hostCell(host) {
                    if host.proxyJump.isEmpty {
                        Label("Direct", systemImage: "arrow.right")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(host.proxyJump, systemImage: "arrow.triangle.branch")
                    }
                }
            }
            .width(min: 110, ideal: 160)

            TableColumn("Environment") { host in
                hostCell(host) {
                    let metadata = model.hostOrganization(for: host.id)
                    Text(metadata.environment.isEmpty ? "Unassigned" : metadata.environment)
                        .foregroundStyle(metadata.environment.isEmpty ? .secondary : .primary)
                }
            }
            .width(min: 90, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onKeyPress(.return) {
            openSelectedHost()
            return model.selectedHostID == nil ? .ignored : .handled
        }
        .help("Double-click a host or press Return to open its SSH session")
    }

    private func hostCell<Content: View>(
        _ host: HostModel,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.openSession(host)
            }
    }

    private func openSelectedHost() {
        guard let selectedHostID = model.selectedHostID,
              let host = model.visibleHosts.first(where: { $0.id == selectedHostID }) else {
            return
        }
        model.openSession(host)
    }

    private var firstRun: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AegizTheme.accent)
            VStack(spacing: 6) {
                Text("Bring your SSH inventory into focus")
                    .font(.system(size: 20, weight: .semibold))
                Text("Aegiz reads host metadata from ~/.ssh/config. Private keys stay where they are and are never copied into the app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("Import SSH Config") {
                Task { await model.importSSHConfig() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Local core unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct HostInspector: View {
    let host: HostModel
    let model: AppModel
    @State private var workspace = ""
    @State private var company = ""
    @State private var environment = ""
    @State private var tags = ""
    @State private var favorite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(AegizTheme.accent)
                        Text(host.alias)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text(host.endpoint)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    model.openSession(host)
                } label: {
                    Label("Open SSH Session", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Divider()
                detail("Connection", value: host.proxyJump.isEmpty ? "Direct" : "via \(host.proxyJump)")
                detail("User", value: host.user.isEmpty ? "OpenSSH default" : host.user)
                detail("Port", value: String(host.port))
                detail("Source", value: host.source)

                if !host.tags.isEmpty {
                    Divider()
                    Text("Tags")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(host.tags.joined(separator: ", "))
                        .font(.system(size: 12))
                }

                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("ORGANIZATION")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Favorite", isOn: $favorite)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                    }
                    TextField("Workspace", text: $workspace)
                        .textFieldStyle(.roundedBorder)
                    TextField("Company", text: $company)
                        .textFieldStyle(.roundedBorder)
                    TextField("Environment", text: $environment)
                        .textFieldStyle(.roundedBorder)
                    TextField("Tags, comma separated", text: $tags)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Organization") {
                        do {
                            try model.saveHostOrganization(
                                HostOrganizationMetadata(
                                    workspace: workspace,
                                    company: company,
                                    environment: environment,
                                    tags: tags.split(separator: ",").map(String.init),
                                    favorite: favorite
                                ),
                                for: host.id
                            )
                        } catch {
                            model.notice = error.localizedDescription
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(18)
        }
        .background(AegizTheme.canvas)
        .onAppear { loadOrganization() }
        .onChange(of: host.id) { _, _ in loadOrganization() }
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private func loadOrganization() {
        let metadata = model.hostOrganization(for: host.id)
        workspace = metadata.workspace
        company = metadata.company
        environment = metadata.environment
        tags = metadata.tags.joined(separator: ", ")
        favorite = metadata.favorite
    }
}
