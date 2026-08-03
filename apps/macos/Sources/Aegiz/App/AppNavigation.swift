import Foundation

/// Presentation-only state for the macOS app shell.
enum CoreConnectionState: Equatable {
    case connecting
    case online
    case unavailable(String)

    var title: String {
        switch self {
        case .connecting: "Connecting"
        case .online: "Local core online"
        case .unavailable: "Core unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "clock.fill"
        case .online: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

/// Stable root routes. Feature views do not own the application shell.
enum AppSection: String, CaseIterable, Identifiable {
    case commandCenter = "Command Center"
    case sessions = "Sessions"
    case tunnels = "Tunnels"
    case hosts = "Hosts"
    case hostOperations = "Host Ops"
    case files = "Files"
    case vault = "Vault"
    case databases = "Databases"
    case containers = "Containers"
    case kubernetes = "Kubernetes"
    case aws = "AWS"
    case automation = "Automation"
    case audit = "Audit"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .commandCenter: "square.grid.2x2"
        case .sessions: "terminal"
        case .tunnels: "point.3.connected.trianglepath.dotted"
        case .hosts: "server.rack"
        case .hostOperations: "waveform.path.ecg.rectangle"
        case .files: "folder"
        case .vault: "key.horizontal"
        case .databases: "cylinder"
        case .containers: "shippingbox"
        case .kubernetes: "hexagon"
        case .aws: "cloud"
        case .automation: "hammer"
        case .audit: "list.bullet.clipboard"
        }
    }
}
