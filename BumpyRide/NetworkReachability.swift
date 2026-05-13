import Foundation
import Network
import Observation

/// Lightweight wrapper around `NWPathMonitor` exposing a single MainActor-isolated
/// `isReachable` flag.  Used as a "kick the sync coordinator early" signal when the
/// device transitions from offline to online — without this, after a transport
/// failure the coordinator would sit on its 30 s → 1 h backoff timer even when the
/// network came back five seconds later.
///
/// "Reachable" here means `NWPath.status == .satisfied`, i.e. the system believes
/// it has a usable path.  That doesn't guarantee successful HTTP — DNS could still
/// fail, the server could be down — but it's the right moment to try again.
@MainActor
@Observable
final class NetworkReachability {
    /// Defaults to `true` so the app doesn't pessimistically suppress sync attempts
    /// before the monitor has reported.  The first real update (which arrives
    /// synchronously soon after `start`) will correct this.
    private(set) var isReachable: Bool = true

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.bumpyride.reachability", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isReachable = reachable
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }
}
