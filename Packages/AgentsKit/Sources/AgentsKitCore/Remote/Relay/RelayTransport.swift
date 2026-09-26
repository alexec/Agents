// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// Why a relayed session ended, or what is slowing it down, in the words the phone
/// shows (046, contracts/ui.md).
public enum RelayTrouble: Error, Sendable, Equatable {
    /// No Mac key: this device has never been on the Mac's network, or was forgotten.
    case notPaired
    /// The Mac deleted this device's zone: it was forgotten (R11).
    case forgotten
    case noICloud
    case iCloudFull
    /// iCloud asked for a pause this long.
    case slowedDown(TimeInterval)
    /// The Mac did not answer the session's opening frame in time.
    case macNotAnswering
    /// A frame went missing for longer than the session waits.
    case gap
}

/// The device's end of one relayed session: a `LineTransport` whose lines go through the
/// person's iCloud rather than a socket (046, R1, contracts/relay.md § Session).
///
/// `DaemonClient` cannot tell it from a TCP connection, which is the point: every screen
/// that works at home works through this, only slower. Each line written is its own
/// frame, sent at once — requests are few, and waiting to batch them would only add to
/// every round trip. What comes back is the Mac's batches, opened, put in order and
/// split into lines.
///
/// A session is opened with an empty frame nought and is ready when the Mac answers with
/// its own; after that, a frame with no lines goes every `keepAlive` of silence so the
/// Mac knows the phone is still there. It ends for good — never reopened — when either
/// side says so, when a frame goes missing too long, or when the zone is gone. The phone
/// then starts a new session, which is a new connection with a full refresh, exactly as
/// after a Mac restart.
public final class RelayTransport: LineTransport, @unchecked Sendable {
    public let session = UUID()
    public let device: UUID

    private let side: Side
    private let stream: AsyncThrowingStream<String, any Error>
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let outgoingStream: AsyncStream<Outgoing>
    private let pokes: AsyncStream<Void>.Continuation
    private let pokeStream: AsyncStream<Void>
    private let pollEvery: Duration
    private let closed = ManagedAtomicFlag()
    private let started = ManagedAtomicFlag()
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    enum Outgoing: Sendable {
        case line(String)
        case keepAlive
        case end
    }

    /// Made with everything it needs and started at once. `open()` waits for the Mac.
    public init(channel: any RelayChannel, device: UUID, key: any RelayKey, macKey: Data,
                pollEvery: Duration = .seconds(1), keepAlive: TimeInterval = 30, patience: TimeInterval = 10,
                onTrouble: @escaping @Sendable (RelayTrouble) -> Void = { _ in }) {
        self.device = device
        self.pollEvery = pollEvery
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream { c = $0 }
        (outgoingStream, outgoing) = AsyncStream<Outgoing>.makeStream()
        (pokeStream, pokes) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        side = Side(channel: channel, device: device, session: session, key: key, macKey: macKey,
                    lines: c, patience: patience, keepAlive: keepAlive, onTrouble: onTrouble)
        c.onTermination = { [weak self] _ in self?.stopTasks() }
    }

    /// Make the zone, say hello, and wait for the Mac to answer. Throws the trouble that
    /// stopped it. Nothing is sent or fetched before this, so frame nought is the hello.
    public func open(timeout: Duration = .seconds(10)) async throws {
        guard started.set() else { return }
        try await side.open()
        let side = side, outgoingStream = outgoingStream, pokeStream = pokeStream, every = pollEvery
        let sending = Task { await side.send(outgoingStream) }
        let polling = Task { await side.poll(every: every, pokes: pokeStream) }
        keep([sending, polling])
        poke()
        do {
            try await side.waitUntilReady(timeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    private func keep(_ running: [Task<Void, Never>]) {
        lock.withLock { tasks = running }
    }

    private func stopTasks() {
        outgoing.finish()
        pokes.finish()
        let running = lock.withLock { () -> [Task<Void, Never>] in defer { tasks = [] }; return tasks }
        for task in running { task.cancel() }
    }

    public func write(line: String) throws {
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        outgoing.yield(.line(line))
        // A request is waiting on an answer, so look for it now rather than at the next tick.
        poke()
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { stream }

    /// Look for the Mac's frames now: a push said some have arrived.
    public func poke() { pokes.yield() }

    public func close() {
        guard closed.set() else { return }
        outgoing.yield(.end)
        outgoing.finish()
        // The stream ends once the end frame has gone, from `Side.send`.
    }

    /// The device's side of the session, one thing at a time.
    actor Side {
        let channel: any RelayChannel
        let device: UUID
        let session: UUID
        let key: any RelayKey
        let macKey: Data
        let lines: AsyncThrowingStream<String, any Error>.Continuation
        let keepAlive: TimeInterval
        let onTrouble: @Sendable (RelayTrouble) -> Void

        var order: FrameOrder
        var nextOut: Int64 = 0
        var lastSent = Date()
        var ready = false
        var finished = false
        var readyWaiters: [CheckedContinuation<Void, any Error>] = []
        /// When the phone last asked something. For a few seconds after, it looks for the
        /// answer four times a second rather than once (R7).
        var askedAt: Date = .distantPast

        init(channel: any RelayChannel, device: UUID, session: UUID, key: any RelayKey, macKey: Data,
             lines: AsyncThrowingStream<String, any Error>.Continuation, patience: TimeInterval,
             keepAlive: TimeInterval, onTrouble: @escaping @Sendable (RelayTrouble) -> Void) {
            self.channel = channel
            self.device = device
            self.session = session
            self.key = key
            self.macKey = macKey
            self.lines = lines
            self.keepAlive = keepAlive
            self.onTrouble = onTrouble
            order = FrameOrder(patience: patience)
        }

        func open() async throws {
            do {
                try await channel.ensureZone(device: device)
            } catch {
                let trouble = Self.trouble(error)
                finish(trouble)
                throw trouble
            }
            try await post(Frame(session: session, direction: .toMac, seq: take()))
        }

        func waitUntilReady(timeout: Duration) async throws {
            if ready { return }
            if finished { throw RelayTrouble.macNotAnswering }
            let waiting = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.giveUpWaiting()
            }
            defer { waiting.cancel() }
            try await withCheckedThrowingContinuation { readyWaiters.append($0) }
        }

        private func giveUpWaiting() {
            guard !ready else { return }
            finish(.macNotAnswering)
        }

        private func take() -> Int64 {
            defer { nextOut += 1 }
            return nextOut
        }

        /// Written lines, one frame each, in the order written.
        func send(_ outgoing: AsyncStream<Outgoing>) async {
            for await item in outgoing {
                guard !finished else { return }
                let frame: Frame
                switch item {
                case .line(let line):
                    askedAt = Date()
                    frame = Frame(session: session, direction: .toMac, seq: take(), lines: [line])
                case .keepAlive: frame = Frame(session: session, direction: .toMac, seq: take())
                case .end: frame = Frame(session: session, direction: .toMac, seq: take(), end: true)
                }
                try? await post(frame)
                if frame.end { finish(nil); return }
            }
        }

        private func post(_ frame: Frame) async throws {
            let sealed = try frame.seal(to: macKey, from: key)
            let record = FrameRecord(session: session, direction: .toMac, seq: frame.seq, sealed: sealed)
            while !finished {
                do {
                    try await channel.post(record, device: device)
                    lastSent = Date()
                    return
                } catch RelayChannelError.slowDown(let seconds) {
                    onTrouble(.slowedDown(seconds))
                    try? await Task.sleep(for: .seconds(seconds))
                } catch {
                    finish(Self.trouble(error))
                    throw error
                }
            }
        }

        /// Fetch every `every`, or at once when poked.
        func poll(every: Duration, pokes: AsyncStream<Void>) async {
            let ticker = Task {
                // A tick is a poke on a timer; the loop below cannot tell them apart.
                while !Task.isCancelled {
                    let waiting = await self.isWaitingOnAnAnswer
                    try? await Task.sleep(for: waiting ? min(every, .milliseconds(250)) : every)
                    await self.tick()
                }
            }
            defer { ticker.cancel() }
            for await _ in pokes {
                guard !finished else { return }
                await fetch()
            }
        }

        var isWaitingOnAnAnswer: Bool { Date().timeIntervalSince(askedAt) < 5 }

        private func tick() async {
            guard !finished else { return }
            if Date().timeIntervalSince(lastSent) > keepAlive {
                lastSent = Date()
                try? await post(Frame(session: session, direction: .toMac, seq: take()))
            }
            await fetch()
        }

        private var fetching = false
        private func fetch() async {
            guard !fetching, !finished else { return }
            fetching = true
            defer { fetching = false }
            let records: [FrameRecord]
            do {
                records = try await channel.fetchChanges(device: device)
            } catch RelayChannelError.slowDown(let seconds) {
                onTrouble(.slowedDown(seconds))
                try? await Task.sleep(for: .seconds(seconds))
                return
            } catch {
                finish(Self.trouble(error))
                return
            }
            var delivered: [String] = []
            for record in records where record.direction == .toDevice && record.session == session {
                delivered.append(record.name)
                guard let frame = try? Frame.open(record.sealed, with: key, from: macKey, session: session,
                                                  direction: .toDevice, seq: record.seq) else { continue }
                for frame in order.accept(frame) {
                    if frame.seq == 0 { becomeReady() }
                    for line in frame.lines { lines.yield(line) }
                    if frame.end { finish(nil); break }
                }
            }
            if order.gapExpired() { finish(.gap) }
            if !delivered.isEmpty { try? await channel.delete(delivered, device: device) }
        }

        private func becomeReady() {
            ready = true
            for waiter in readyWaiters { waiter.resume() }
            readyWaiters = []
        }

        private func finish(_ trouble: RelayTrouble?) {
            guard !finished else { return }
            finished = true
            for waiter in readyWaiters { waiter.resume(throwing: trouble ?? .macNotAnswering) }
            readyWaiters = []
            if let trouble { onTrouble(trouble) }
            if let trouble { lines.finish(throwing: trouble) } else { lines.finish() }
        }

        static func trouble(_ error: any Error) -> RelayTrouble {
            switch error as? RelayChannelError {
            case .zoneGone: .forgotten
            case .full: .iCloudFull
            case .noAccount: .noICloud
            case .slowDown(let seconds): .slowedDown(seconds)
            case nil: .macNotAnswering
            }
        }
    }
}
#endif
