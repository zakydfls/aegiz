import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var inspectorPresented = true
    @State private var availableWidth: CGFloat = 1_200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: AegizTheme.Layout.sidebarMinimumWidth,
                    ideal: AegizTheme.Layout.sidebarIdealWidth,
                    max: AegizTheme.Layout.sidebarMaximumWidth
                )
        } detail: {
            content
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .navigationSplitViewColumnWidth(min: 480, ideal: 920)
        }
        .inspector(isPresented: $inspectorPresented) {
            Inspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .tint(AegizTheme.accent)
        .background(AegizTheme.canvas)
        .background {
            WindowWidthReader { width in
                updateInspector(for: width)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || model.connectionState != .online)
            }
            if supportsInspector {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Label("Toggle Inspector", systemImage: "sidebar.right")
                    }
                    .help(inspectorPresented ? "Hide inspector" : "Show inspector")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBar(message: notice) {
                    let duration = AegizInteractionPolicy.transitionDuration(
                        reduceMotion: reduceMotion
                    )
                    withAnimation(duration == 0 ? nil : .easeOut(duration: duration)) {
                        model.notice = nil
                    }
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $model.showingNewTunnel) {
            NewTunnelView(model: model)
        }
        .sheet(isPresented: $model.showingCommandPalette) {
            CommandPaletteView(model: model)
        }
        .sheet(isPresented: $model.showingNewSecret) {
            NewSecretView(model: model)
        }
        .sheet(isPresented: $model.showingDatabaseProfileEditor) {
            DatabaseProfileEditorView(model: model)
        }
        .onChange(of: model.selectedSection) { _, _ in
            inspectorPresented = supportsInspector
                && availableWidth >= AegizTheme.Layout.inspectorRevealWidth
        }
    }

    private var supportsInspector: Bool {
        switch model.selectedSection ?? .commandCenter {
        case .commandCenter, .hosts, .sessions, .tunnels: true
        default: false
        }
    }

    private func updateInspector(for width: CGFloat) {
        availableWidth = width
        inspectorPresented = supportsInspector
            && width >= AegizTheme.Layout.inspectorRevealWidth
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedSection ?? .commandCenter {
        case .commandCenter, .hosts:
            CommandCenterView(model: model)
        case .sessions:
            SessionWorkspaceView(model: model)
        case .tunnels:
            TunnelManagerView(model: model)
        case .hostOperations:
            HostOperationsView(model: model)
        case .files:
            FilesView(model: model)
        case .vault:
            VaultView(model: model)
        case .databases:
            DatabaseView(model: model)
        case .containers:
            DockerView(model: model)
        case .kubernetes:
            KubernetesView(model: model)
        case .aws:
            AWSView(model: model)
        case .automation:
            AutomationView(model: model)
        case .audit:
            AuditView(model: model)
        }
    }
}

/// Reads the containing window instead of the split view's proposed width. The
/// latter already excludes an open inspector, which can keep the inspector open
/// while squeezing the navigation sidebar at compact window sizes.
private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowWidthProbeView {
        let view = WindowWidthProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowWidthProbeView, context: Context) {
        nsView.onChange = onChange
        nsView.reportCurrentWidth()
    }
}

private final class WindowWidthProbeView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private weak var observedWindow: NSWindow?
    private var lastReportedWidth: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
    }

    func reportCurrentWidth() {
        guard let width = window?.frame.width else { return }
        guard lastReportedWidth.map({ abs($0 - width) >= 1 }) ?? true else { return }
        lastReportedWidth = width
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(width)
        }
    }

    private func observeWindow() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResizeNotification,
                object: observedWindow
            )
        }

        observedWindow = window
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window,
        )
        reportCurrentWidth()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        reportCurrentWidth()
    }
}

private struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var query = ""

    private var actions: [(String, String, () -> Void)] {
        let navigation = AppSection.allCases.map { section in
            (
                "Open \(section.rawValue)",
                section.symbol,
                { model.selectedSection = section }
            )
        }
        return (navigation + [
            ("New Tunnel", "plus", { model.showingNewTunnel = true }),
            ("New Database Profile", "cylinder.badge.plus", {
                model.beginCreatingDatabaseProfile()
            }),
            ("New Vault Secret", "key.horizontal", {
                model.beginCreatingSecret()
            }),
            ("Import SSH Config", "square.and.arrow.down", {
                Task { await model.importSSHConfig() }
            }),
            ("Refresh Inventory", "arrow.clockwise", {
                Task { await model.refresh() }
            }),
        ]).filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search actions and resources", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()
            List {
                Section("Actions") {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button {
                            dismiss()
                            action.2()
                        } label: {
                            Label(action.0, systemImage: action.1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                        .aegizInteractiveRow()
                    }
                }
                if !model.hosts.isEmpty {
                    Section("Hosts") {
                        ForEach(model.hosts.filter {
                            query.isEmpty ||
                            $0.alias.localizedCaseInsensitiveContains(query) ||
                            $0.hostname.localizedCaseInsensitiveContains(query)
                        }.prefix(8)) { host in
                            Button {
                                dismiss()
                                model.openSession(host)
                            } label: {
                                HStack {
                                    Label(host.alias, systemImage: "server.rack")
                                    Spacer()
                                    Text(host.hostname)
                                        .font(.system(size: 10).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .aegizInteractiveRow()
                        }
                    }
                }
                if !model.tunnels.isEmpty {
                    Section("Tunnels") {
                        ForEach(model.tunnels.filter {
                            query.isEmpty
                                || $0.label.localizedCaseInsensitiveContains(query)
                                || $0.remoteHost.localizedCaseInsensitiveContains(query)
                        }.prefix(8)) { tunnel in
                            Button {
                                dismiss()
                                model.selectedSection = .tunnels
                            } label: {
                                HStack {
                                    Label(tunnel.label, systemImage: "point.3.connected.trianglepath.dotted")
                                    Spacer()
                                    Text(model.tunnelRoute(for: tunnel))
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .aegizInteractiveRow()
                        }
                    }
                }
                if !model.databaseProfiles.isEmpty {
                    Section("Databases") {
                        ForEach(model.databaseProfiles.filter {
                            query.isEmpty
                                || $0.label.localizedCaseInsensitiveContains(query)
                                || $0.hostname.localizedCaseInsensitiveContains(query)
                        }.prefix(8)) { profile in
                            Button {
                                dismiss()
                                model.selectedSection = .databases
                            } label: {
                                HStack {
                                    Label(profile.label, systemImage: "cylinder")
                                    Spacer()
                                    Text(profile.endpoint)
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .aegizInteractiveRow()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .aegizAdaptiveSheet(AegizSheetSizingPolicy.commandPalette)
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    SidebarNavigationGroup {
                        sidebarRow(.commandCenter)
                        sidebarRow(.sessions)
                        sidebarRow(.tunnels, count: model.dashboard.activeTunnels)
                        sidebarRow(.hosts, count: model.dashboard.hosts)
                        sidebarRow(.hostOperations)
                    }
                    SidebarNavigationGroup("Resources") {
                        sidebarRow(.files)
                        sidebarRow(.vault, count: model.secrets.count)
                        sidebarRow(.databases)
                        sidebarRow(.containers)
                        sidebarRow(.kubernetes)
                        sidebarRow(.aws)
                    }
                    SidebarNavigationGroup("Operations") {
                        sidebarRow(.automation)
                        sidebarRow(.audit, count: model.dashboard.attention)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            SidebarFooter(state: model.connectionState)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    private func sidebarRow(_ section: AppSection, count: Int = 0) -> some View {
        AegizSidebarRow(
            section: section,
            count: count,
            isSelected: model.selectedSection == section
        ) {
            model.selectedSection = section
        }
    }
}

private struct SidebarNavigationGroup<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AegizSidebarRow: View {
    let section: AppSection
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    private var displayCount: String? {
        guard count > 0 else { return nil }
        return count > 999 ? "999+" : count.formatted()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AegizTheme.accent : .secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let displayCount {
                    Text(displayCount)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? AegizTheme.accent : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 17)
                        .background(
                            Capsule()
                                .fill(
                                    isSelected
                                        ? AegizTheme.accent.opacity(0.16)
                                        : Color.primary.opacity(0.07)
                                )
                        )
                        .accessibilityLabel("\(count) items")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AegizTheme.Radius.control)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .animation(stateAnimation, value: isHovered)
        .animation(stateAnimation, value: isSelected)
    }

    private var backgroundColor: Color {
        let increasedContrast = accessibilityContrast == .increased
        if isSelected { return AegizTheme.selected(increasedContrast: increasedContrast) }
        if isHovered { return AegizTheme.hover(increasedContrast: increasedContrast) }
        return .clear
    }

    private var stateAnimation: Animation? {
        let duration = AegizInteractionPolicy.transitionDuration(reduceMotion: reduceMotion)
        return duration == 0 ? nil : .easeOut(duration: duration)
    }
}

private struct SidebarFooter: View {
    let state: CoreConnectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConnectionBadge(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AegizTheme.accent)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local-only")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("No cloud custody")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AegizTheme.raised, in: RoundedRectangle(cornerRadius: AegizTheme.Radius.panel))
    }
}

private struct Inspector: View {
    let model: AppModel

    var body: some View {
        if let host = model.selectedHost,
           model.selectedSection == .commandCenter || model.selectedSection == .hosts {
            HostInspector(host: host, model: model)
        } else if let session = model.sessionHost, model.selectedSection == .sessions {
            HostInspector(host: session, model: model)
        } else if model.selectedSection == .tunnels {
            TunnelInspector(model: model)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a resource")
                    .font(.headline)
                Text("Details and safe actions appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ConnectionBadge: View {
    let state: CoreConnectionState

    var color: Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        case .unavailable: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .foregroundStyle(color)
            Text(state.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 24)
        .background(color.opacity(0.10), in: Capsule())
        .help("Aegiz local core: \(state.title)")
        .accessibilityElement(children: .combine)
    }
}

private struct NoticeBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AegizTheme.accent)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .aegizIconAction("Dismiss notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notice: \(message)")
        .background(AccessibilityAnnouncementView(message: message))
    }
}

private struct AccessibilityAnnouncementView: NSViewRepresentable {
    let message: String

    final class Coordinator {
        var lastMessage: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !message.isEmpty, context.coordinator.lastMessage != message else { return }
        context.coordinator.lastMessage = message
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            NSAccessibility.post(
                element: nsView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}
