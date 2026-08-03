/// The single composition boundary for macOS-only infrastructure services.
///
/// Feature code receives its state through `AppModel`; construction of gRPC
/// and Keychain implementations remains at the app boundary instead of being
/// scattered across views.
@MainActor
struct AppDependencies {
    let core: CoreClient
    let vault: KeychainVault

    static func live() -> Self {
        Self(core: CoreClient(), vault: KeychainVault())
    }
}
