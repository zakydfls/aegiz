import SwiftUI

enum AegizTheme {
    static let accent = Color(
        light: NSColor(red: 0.10, green: 0.48, blue: 0.41, alpha: 1),
        dark: NSColor(red: 0.34, green: 0.76, blue: 0.66, alpha: 1)
    )
    static let canvas = Color(
        light: NSColor(red: 0.965, green: 0.968, blue: 0.963, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.085, blue: 0.083, alpha: 1)
    )
    static let raised = Color(
        light: NSColor(red: 0.995, green: 0.995, blue: 0.99, alpha: 1),
        dark: NSColor(red: 0.11, green: 0.12, blue: 0.117, alpha: 1)
    )
    static let subtleBorder = Color.primary.opacity(0.10)
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    enum Spacing {
        static let compact: CGFloat = 6
        static let standard: CGFloat = 12
        static let section: CGFloat = 16
        static let page: CGFloat = 20
    }

    enum Radius {
        static let control: CGFloat = 7
        static let panel: CGFloat = 10
    }

    enum Layout {
        static let minimumWindowWidth: CGFloat = 1_080
        static let minimumWindowHeight: CGFloat = 680
        static let defaultWindowWidth: CGFloat = 1_320
        static let defaultWindowHeight: CGFloat = 820
        static let inspectorRevealWidth: CGFloat = 1_280
        static let sidebarMinimumWidth: CGFloat = 208
        static let sidebarIdealWidth: CGFloat = 224
        static let sidebarMaximumWidth: CGFloat = 252
    }

    /// Terminal surfaces deliberately stay dark in both system appearances.
    /// This gives long-running infrastructure sessions a stable visual anchor
    /// while the surrounding app continues to follow macOS appearance.
    enum Terminal {
        static let background = Color(
            nsColor: NSColor(red: 0.055, green: 0.071, blue: 0.067, alpha: 1)
        )
        static let chrome = Color(
            nsColor: NSColor(red: 0.078, green: 0.098, blue: 0.091, alpha: 1)
        )
        static let raised = Color(
            nsColor: NSColor(red: 0.105, green: 0.132, blue: 0.122, alpha: 1)
        )
        static let border = Color.white.opacity(0.09)
        static let text = Color(
            nsColor: NSColor(red: 0.863, green: 0.910, blue: 0.890, alpha: 1)
        )
        static let muted = Color(
            nsColor: NSColor(red: 0.58, green: 0.66, blue: 0.63, alpha: 1)
        )
        static let accent = Color(
            nsColor: NSColor(red: 0.45, green: 0.84, blue: 0.74, alpha: 1)
        )
    }

    static func hover(increasedContrast: Bool) -> Color {
        Color.primary.opacity(AegizInteractionPolicy.hoverOpacity(increasedContrast: increasedContrast))
    }

    static func selected(increasedContrast: Bool) -> Color {
        accent.opacity(
            AegizInteractionPolicy.selectedOpacity(increasedContrast: increasedContrast)
        )
    }

    static func statusColor(_ status: TunnelStatusModel) -> Color {
        switch status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

enum AegizInteractionPolicy {
    static let minimumPointerTarget: CGFloat = 28

    static func transitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.12
    }

    static func hoverOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.12 : 0.055
    }

    static func selectedOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.24 : 0.14
    }
}

struct AegizSheetSize: Equatable {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat
    let maxHeight: CGFloat

    var hasOrderedBounds: Bool {
        minWidth <= idealWidth
            && idealWidth <= maxWidth
            && minHeight <= idealHeight
            && idealHeight <= maxHeight
    }
}

enum AegizSheetSizingPolicy {
    static let commandPalette = AegizSheetSize(
        minWidth: 440,
        idealWidth: 580,
        maxWidth: 720,
        minHeight: 320,
        idealHeight: 430,
        maxHeight: 650
    )
    static let secretEditor = AegizSheetSize(
        minWidth: 420,
        idealWidth: 470,
        maxWidth: 640,
        minHeight: 320,
        idealHeight: 390,
        maxHeight: 620
    )
    static let tunnelEditor = AegizSheetSize(
        minWidth: 480,
        idealWidth: 560,
        maxWidth: 720,
        minHeight: 420,
        idealHeight: 590,
        maxHeight: 780
    )
    static let databaseEditor = AegizSheetSize(
        minWidth: 460,
        idealWidth: 520,
        maxWidth: 700,
        minHeight: 420,
        idealHeight: 610,
        maxHeight: 780
    )
    static let terminalSettings = AegizSheetSize(
        minWidth: 520,
        idealWidth: 640,
        maxWidth: 820,
        minHeight: 460,
        idealHeight: 650,
        maxHeight: 850
    )
    static let backup = AegizSheetSize(
        minWidth: 420,
        idealWidth: 480,
        maxWidth: 640,
        minHeight: 340,
        idealHeight: 420,
        maxHeight: 620
    )

    static let all: [AegizSheetSize] = [
        commandPalette,
        secretEditor,
        tunnelEditor,
        databaseEditor,
        terminalSettings,
        backup,
    ]
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua])
            return best == .darkAqua ? dark : light
        })
    }
}
