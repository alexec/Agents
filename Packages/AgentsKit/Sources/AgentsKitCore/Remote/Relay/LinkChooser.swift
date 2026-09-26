// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// Which way the device is reaching the Mac right now (046, data-model.md § Link).
public enum RemoteLink: Sendable, Hashable {
    case direct
    case relayed
    case none
}

/// The phone's one `DaemonLink`, which is two: the direct link on the Mac's own network,
/// and the relay through iCloud everywhere else (046, R8).
///
/// Both are tried at once, because a Bonjour browse on a network with no Mac does not
/// fail, it goes quiet, and a person on a train would otherwise watch a spinner for as
/// long as we were willing to wait. The direct link wins if it is up within `window`;
/// after that, whichever answers first. While on the relay, the chooser keeps looking
/// for the Mac nearby, and when it answers it closes the relayed transport: the model's
/// ordinary lost-touch path reconnects, and this time the direct link wins. So coming
/// home needs no state machine of its own — it is a reconnect, the same one a Mac
/// restart causes.
public final class LinkChooser: DaemonLink, @unchecked Sendable {
    public typealias MakeTransport = @Sendable () async throws -> any LineTransport

    private let direct: MakeTransport
    private let relay: MakeTransport
    private let probe: MakeTransport
    private let window: Duration
    private let probeEvery: Duration

    private let lock = NSLock()
    private var current: RemoteLink = .none
    private var watching: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<RemoteLink>.Continuation] = [:]

    /// `direct` and `probe` are usually the same Bonjour link with different patience;
    /// `relay` makes a session and returns once the Mac has answered it.
    public init(direct: @escaping MakeTransport, relay: @escaping MakeTransport,
                probe: MakeTransport? = nil, window: Duration = .seconds(2), probeEvery: Duration = .seconds(5)) {
        self.direct = direct
        self.relay = relay
        self.probe = probe ?? direct
        self.window = window
        self.probeEvery = probeEvery
    }

    public var link: RemoteLink { lock.withLock { current } }

    /// The link as it changes, starting with what it is now.
    public func links() -> AsyncStream<RemoteLink> {
        let (stream, continuation) = AsyncStream<RemoteLink>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            observers[id] = continuation
            continuation.yield(current)
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    private func set(_ link: RemoteLink) {
        let listeners = lock.withLock { () -> [AsyncStream<RemoteLink>.Continuation] in
            current = link
            return Array(observers.values)
        }
        for listener in listeners { listener.yield(link) }
    }

    /// Say the link is gone, from the model's lost-touch path.
    public func lost() { set(.none) }

    enum Event: Sendable {
        case direct(Result<any LineTransport, any Error>)
        case relay(Result<any LineTransport, any Error>)
        case windowOver
    }

    public func transport() async throws -> any LineTransport {
        lock.withLock { watching?.cancel(); watching = nil }
        let (events, sink) = AsyncStream<Event>.makeStream()
        let direct = direct, relay = relay, window = window
        let directLeg = Task {
            let result: Result<any LineTransport, any Error>
            do { result = .success(try await direct()) } catch { result = .failure(error) }
            sink.yield(.direct(result))
            return result
        }
        let relayLeg = Task {
            let result: Result<any LineTransport, any Error>
            do { result = .success(try await relay()) } catch { result = .failure(error) }
            sink.yield(.relay(result))
            return result
        }
        let timer = Task {
            try? await Task.sleep(for: window)
            sink.yield(.windowOver)
        }
        defer { timer.cancel(); sink.finish() }

        var windowOver = false
        var directFailed = false
        var relayReady: (any LineTransport)?
        var relayError: (any Error)?

        func useRelay(_ transport: any LineTransport) -> any LineTransport {
            // The direct leg may still come up; if it does it is not wanted this time.
            Task { if case .success(let late) = await directLeg.value { late.close() } }
            set(.relayed)
            watchForTheMac(while: transport)
            return transport
        }

        for await event in events {
            switch event {
            case .direct(.success(let transport)):
                relayLeg.cancel()
                Task { if case .success(let late) = await relayLeg.value { late.close() } }
                set(.direct)
                return transport
            case .direct(.failure):
                directFailed = true
                if let relayReady { return useRelay(relayReady) }
                if let relayError { set(.none); throw relayError }
            case .relay(.success(let transport)):
                if windowOver || directFailed { return useRelay(transport) }
                relayReady = transport
            case .relay(.failure(let error)):
                relayError = error
                if directFailed { set(.none); throw error }
            case .windowOver:
                windowOver = true
                if let relayReady { return useRelay(relayReady) }
            }
        }
        set(.none)
        throw relayError ?? JSONRPCTransportError.closed
    }

    /// While on the relay, look for the Mac nearby every `probeEvery`; when it answers,
    /// close the relayed transport so the model reconnects, and the direct link wins.
    private func watchForTheMac(while relayed: any LineTransport) {
        let probe = probe, every = probeEvery
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                if let nearby = try? await probe() {
                    nearby.close()
                    guard !Task.isCancelled else { return }
                    self?.set(.none)
                    relayed.close()
                    return
                }
            }
        }
        lock.withLock { watching = task }
    }
}
#endif
