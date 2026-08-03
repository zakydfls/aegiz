import AppKit
import SwiftUI

@main
struct AegizApp: App {
    @NSApplicationDelegateAdaptor(AegizAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AegizWindowCoordinator.shared.register(model: model)
    }

    var body: some Scene {
        WindowGroup("Aegiz", id: "main") {
            RootView(model: model)
                .frame(
                    minWidth: AegizTheme.Layout.minimumWindowWidth,
                    minHeight: AegizTheme.Layout.minimumWindowHeight
                )
                .task { await model.start() }
                .onDisappear {
                    // Window close intentionally does not stop the local core or tunnels.
                }
        }
        .defaultSize(
            width: AegizTheme.Layout.defaultWindowWidth,
            height: AegizTheme.Layout.defaultWindowHeight
        )
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Command Palette…") {
                    model.showingCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    if let host = model.selectedHost {
                        model.openSession(host)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.selectedHost == nil)

                Button("New Tunnel…") {
                    model.showingNewTunnel = true
                    model.selectedSection = .tunnels
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Infrastructure") {
                Button("Import SSH Config") {
                    Task { await model.importSSHConfig() }
                }
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Aegiz", systemImage: "shield.lefthalf.filled") {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Label(model.connectionState.title, systemImage: model.connectionState.symbol)
        Text("\(model.dashboard.activeTunnels) active tunnels")
        Divider()
        Button("Show Aegiz") {
            openWindow(id: "main")
            AegizWindowCoordinator.shared.show(model: model)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Aegiz") {
            model.shutdown()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class AegizWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = AegizWindowCoordinator()
    private var window: NSWindow?
    private var model: AppModel?

    func register(model: AppModel) {
        self.model = model
    }

    func showRegisteredModel() {
        guard let model else { return }
        show(model: model)
    }

    func show(model: AppModel) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let existing = NSApp.windows.first(where: {
            $0.isVisible &&
                $0.styleMask.contains(.titled) &&
                !($0 is NSPanel) &&
                $0.level == .normal &&
                $0.contentViewController != nil
        }) {
            window = existing
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = RootView(model: model)
            .frame(
                minWidth: AegizTheme.Layout.minimumWindowWidth,
                minHeight: AegizTheme.Layout.minimumWindowHeight
            )
            .task { await model.start() }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "Aegiz"
        window.setContentSize(
            NSSize(
                width: AegizTheme.Layout.defaultWindowWidth,
                height: AegizTheme.Layout.defaultWindowHeight
            )
        )
        window.minSize = NSSize(
            width: AegizTheme.Layout.minimumWindowWidth,
            height: AegizTheme.Layout.minimumWindowHeight
        )
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class AegizAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let hasVisibleWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }
            if !hasVisibleWindow {
                AegizWindowCoordinator.shared.showRegisteredModel()
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            AegizWindowCoordinator.shared.showRegisteredModel()
        }
        return true
    }
}
