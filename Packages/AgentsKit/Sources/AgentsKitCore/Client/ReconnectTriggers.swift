import Foundation
#if canImport(Network)
import Network
#endif

/// Whether a network path report is worth trying again for (#82).
///
/// The first report is how things were at the start, and nothing has changed yet. After
/// that: a path that has just become usable, or a usable one that now goes another way
/// (Wi-Fi to cellular, another Wi-Fi, a VPN coming up). A path going away is not: there
/// is nothing to dial over until it comes back, and that is its own report.
public struct PathChange: Sendable {
    public struct Path: Equatable, Sendable {
        public var satisfied: Bool
        /// The interfaces and gateways it uses, which say which network it is.
        public var route: [String]

        public init(satisfied: Bool, route: [String]) {
            self.satisfied = satisfied
            self.route = route
        }
    }

    private var last: Path?

    public init() {}

    public mutating func retries(after path: Path) -> Bool {
        defer { last = path }
        guard let last, path.satisfied else { return false }
        return !last.satisfied || last.route != path.route
    }
}

/// What tells a client to go back now rather than when its backoff says (#82).
///
/// A network path that became usable or changed, and whatever wake notifications the
/// app names (the Mac window's `NSWorkspace.didWakeNotification`). Each says so to
/// `onTrigger`, on `queue` (the main queue unless a process without one names another);
/// what to do about it is the caller's.
public final class ReconnectTriggers: @unchecked Sendable {
    public enum Reason: String, Sendable {
        case wake
        case network
    }

    public struct Wake: @unchecked Sendable {
        public let center: NotificationCenter
        public let name: Notification.Name

        public init(center: NotificationCenter, name: Notification.Name) {
            self.center = center
            self.name = name
        }
    }

    private let onTrigger: @Sendable (Reason) -> Void
    private let wakes: [Wake]
    private let watchesPaths: Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var paths = PathChange()
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    /// `watchesPaths` false leaves the system's paths out, for a test that gives its own.
    public init(wakes: [Wake] = [], watchesPaths: Bool = true, queue: DispatchQueue = .main,
                onTrigger: @escaping @Sendable (Reason) -> Void) {
        self.wakes = wakes
        self.watchesPaths = watchesPaths
        self.queue = queue
        self.onTrigger = onTrigger
    }

    public func start() {
        lock.withLock {
            guard observers.isEmpty else { return }
            for wake in wakes {
                let observer = wake.center.addObserver(forName: wake.name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.fire(.wake) }
                }
                observers.append((wake.center, observer))
            }
            #if canImport(Network)
            guard watchesPaths else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(Self.describe(path)) }
            monitor.start(queue: queue)
            self.monitor = monitor
            #endif
        }
    }

    public func stop() {
        let ended = lock.withLock {
            defer { observers = [] }
            #if canImport(Network)
            monitor?.cancel()
            monitor = nil
            #endif
            return observers
        }
        for (center, observer) in ended { center.removeObserver(observer) }
    }

    /// A path report, from the monitor or a test.
    public func pathChanged(_ path: PathChange.Path) {
        let retries = lock.withLock { paths.retries(after: path) }
        if retries { fire(.network) }
    }

    /// As if the system had said it: for the monitor, the observers, and a debug hook.
    public func fire(_ reason: Reason) {
        onTrigger(reason)
    }

    #if canImport(Network)
    private static func describe(_ path: NWPath) -> PathChange.Path {
        let interfaces = path.availableInterfaces.map(\.name).sorted()
        let gateways = path.gateways.map { "\($0)" }.sorted()
        return PathChange.Path(satisfied: path.status == .satisfied, route: interfaces + gateways)
    }
    #endif
}
