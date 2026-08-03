import Foundation

/// Main-actor timer scheduling used by UI-owned security expiry state.
///
/// This keeps cancellation-sensitive timing outside feature stores and avoids
/// detached task lifetime issues around Touch ID callbacks.
@MainActor
enum AegizMainRunLoopTimer {
    static func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
