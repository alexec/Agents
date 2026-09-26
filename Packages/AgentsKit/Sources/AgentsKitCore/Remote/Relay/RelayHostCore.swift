// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// The Mac's end of every relayed session: frames from each paired device's zone in,
/// lines to a daemon connection of that session's own, and the daemon's lines back out
/// in batches (046, R2, contracts/relay.md).
///
/// It is the relayed twin of the bridge's `Relay`, which does the same for a device on
/// the LAN with a TCP stream: one device session, one daemon connection, lines carried
/// and never read. What it adds is what iCloud needs — sealing, ordering, batching,
/// deleting what it has read — and the one check the LAN relay does not make: nothing is
/// opened, let alone carried, from a device the daemon does not list as paired (FR-008).
///
/// Here in Core rather than in the bridge so that `swift test` runs it whole against a
/// real daemon and a fake iCloud. The bridge gives it CloudKit, the Mac's key, a way to
/// open the daemon's socket, and the paired devices it hears about.
public actor RelayHostCore {
    public typealias OpenDaemon = @Sendable () async throws -> any LineTransport

    private let channel: any RelayChannel
    private let key: any RelayKey
    private let openDaemon: OpenDaemon
    private let clock: @Sendable () -> Date
    private let window: TimeInterval
    private let silence: TimeInterval
    private let patience: TimeInterval
    private let livePoll: TimeInterval
    private let idlePoll: TimeInterval
    private let startedAt: Date

    private var paired: [UUID: Data] = [:]
    private var sessions: [UUID: Session] = [:]
    private var lastLive: Date = .distantPast
    private var lookedForNewSessionsAt: Date = .distantPast
    /// How soon an answer goes after the device asked: long enough to catch a reply and
    /// the notifications that come with it in one frame, short enough not to be felt.
    private let answerWindow: TimeInterval = 0.05

    final class Session {
        let id: UUID
        let device: UUID
        var order: FrameOrder
        var batcher: LineBatcher
        var nextOut: Int64 = 0
        var lastHeard: Date
        var daemon: (any LineTransport)?
        var reading: Task<Void, Never>?
        /// The device has just asked something: the next thing the daemon says is very
        /// likely the answer, and a person is waiting on it, so it goes without the
        /// batching window. Nothing is parsed to know this — it is only timing.
        var askedAt: Date?

        init(id: UUID, device: UUID, patience: TimeInterval, window: TimeInterval, now: Date) {
            self.id = id
            self.device = device
            order = FrameOrder(patience: patience)
            batcher = LineBatcher(window: window)
            lastHeard = now
        }
    }

    public init(channel: any RelayChannel, key: any RelayKey, openDaemon: @escaping OpenDaemon,
                window: TimeInterval = 0.4, silence: TimeInterval = 120, patience: TimeInterval = 10,
                livePoll: TimeInterval = 0.5, idlePoll: TimeInterval = 5,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.livePoll = livePoll
        self.idlePoll = idlePoll
        self.channel = channel
        self.key = key
        self.openDaemon = openDaemon
        self.window = window
        self.silence = silence
        self.patience = patience
        self.clock = clock
        startedAt = clock()
    }

    // MARK: Who may be carried for

    /// The paired devices and their keys, as the daemon lists them. A device that has
    /// dropped off the list is forgotten here too.
    public func setPaired(_ devices: [UUID: Data]) async {
        let gone = Set(paired.keys).subtracting(devices.keys)
        paired = devices
        for device in gone { await forget(device) }
    }

    public func pair(_ device: UUID, key: Data) {
        paired[device] = key
    }

    /// End the device's session and delete its zone, so a lost phone finds nothing to
    /// write to and says it is no longer paired (R11).
    public func forget(_ device: UUID) async {
        paired.removeValue(forKey: device)
        if let session = sessions.removeValue(forKey: device) { close(session) }
        try? await channel.deleteZone(device: device)
    }

    public var liveSessions: Int { sessions.count }

    /// How long to wait before the next poll: quick while anybody is here, slow otherwise.
    public var pollInterval: TimeInterval {
        clock().timeIntervalSince(lastLive) < 120 ? livePoll : idlePoll
    }

    // MARK: Carrying

    /// One pass: what has arrived, then whatever is due to go.
    public func poll() async throws {
        // A live session's zone is read directly every pass. Asking which zones changed is
        // a round trip of its own, so while anybody is here it is only asked every few
        // seconds, for a device that is starting a session (R7).
        var devices = Set(sessions.keys)
        if sessions.isEmpty || clock().timeIntervalSince(lookedForNewSessionsAt) > 3 {
            lookedForNewSessionsAt = clock()
            devices.formUnion(try await channel.changedDevices())
        }
        for device in devices where paired[device] != nil {
            let records: [FrameRecord]
            do {
                records = try await channel.fetchChanges(device: device)
            } catch RelayChannelError.zoneGone {
                if let session = sessions.removeValue(forKey: device) { close(session) }
                continue
            }
            await receive(records.filter { $0.direction == .toMac }, from: device)
        }
        await tick()
    }

    /// Batches whose time has come, sessions that have gone quiet, gaps left too long.
    public func tick() async {
        let now = clock()
        for session in Array(sessions.values) {
            if let lines = session.batcher.takeIfDue(now: now) { await post(lines, in: session) }
            if now.timeIntervalSince(session.lastHeard) > silence || session.order.gapExpired(now: now) {
                await end(session, telling: true)
            }
        }
        if !sessions.isEmpty { lastLive = now }
    }

    private func receive(_ records: [FrameRecord], from device: UUID) async {
        guard let deviceKey = paired[device] else { return }
        var read: [String] = []
        for record in records.sorted(by: { $0.seq < $1.seq }) {
            read.append(record.name)
            guard let frame = try? Frame.open(record.sealed, with: key, from: deviceKey, session: record.session,
                                              direction: .toMac, seq: record.seq) else { continue }
            let session: Session
            if let current = sessions[device], current.id == frame.session {
                session = current
            } else {
                // Only a session's opening frame starts one, and only one sent since this
                // bridge started: a zone read from the beginning after a restart holds old
                // sessions' frames, which are nobody's now.
                guard frame.seq == 0, record.sentAt >= startedAt.addingTimeInterval(-60) else { continue }
                if let old = sessions[device] { await end(old, telling: true) }
                session = Session(id: frame.session, device: device, patience: patience, window: window, now: clock())
                sessions[device] = session
            }
            session.lastHeard = clock()
            if !frame.lines.isEmpty { session.askedAt = clock() }
            for ready in session.order.accept(frame, now: clock()) {
                if ready.seq == 0 { await open(session) }
                for line in ready.lines { try? session.daemon?.write(line: line) }
                if ready.end { await end(session, telling: false); break }
            }
        }
        if !read.isEmpty { try? await channel.delete(read, device: device) }
    }

    /// The session's own connection to the daemon, and the Mac's frame nought to say the
    /// session is open.
    private func open(_ session: Session) async {
        do {
            let daemon = try await openDaemon()
            session.daemon = daemon
            let id = session.id
            let device = session.device
            session.reading = Task { [weak self] in
                do {
                    for try await line in daemon.lines() { await self?.daemonSaid(line, session: id, device: device) }
                } catch {}
                await self?.daemonWent(session: id, device: device)
            }
            await post([], in: session)
        } catch {
            await end(session, telling: true)
        }
    }

    private func daemonSaid(_ line: String, session id: UUID, device: UUID) async {
        guard let session = sessions[device], session.id == id else { return }
        let now = clock()
        if let full = session.batcher.append(line, now: now) { await post(full, in: session) }
        if let asked = session.askedAt, now.timeIntervalSince(asked) < 5 {
            session.askedAt = nil
            // Wait only a moment for what comes with it, then send.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.answerWindow ?? 0.05))
                await self?.flush(session: id, device: device)
            }
        }
    }

    private func flush(session id: UUID, device: UUID) async {
        guard let session = sessions[device], session.id == id, let lines = session.batcher.flush() else { return }
        await post(lines, in: session)
    }

    private func daemonWent(session id: UUID, device: UUID) async {
        guard let session = sessions[device], session.id == id else { return }
        await end(session, telling: true)
    }

    private func post(_ lines: [String], in session: Session, end: Bool = false) async {
        guard let deviceKey = paired[session.device] else { return }
        let frame = Frame(session: session.id, direction: .toDevice, seq: session.nextOut, lines: lines, end: end)
        session.nextOut += 1
        guard let sealed = try? frame.seal(to: deviceKey, from: key) else { return }
        let record = FrameRecord(session: session.id, direction: .toDevice, seq: frame.seq, sealed: sealed, sentAt: clock())
        for _ in 0..<5 {
            do {
                try await channel.post(record, device: session.device)
                return
            } catch RelayChannelError.slowDown(let seconds) {
                try? await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
        }
    }

    private func end(_ session: Session, telling: Bool) async {
        guard sessions[session.device]?.id == session.id else { return }
        sessions.removeValue(forKey: session.device)
        if let lines = session.batcher.flush() { await post(lines, in: session) }
        if telling { await post([], in: session, end: true) }
        close(session)
    }

    private func close(_ session: Session) {
        session.reading?.cancel()
        session.daemon?.close()
        session.daemon = nil
    }

    /// Run until cancelled: poll, and in between, send what is due.
    public func run() async {
        while !Task.isCancelled {
            do {
                try await poll()
            } catch RelayChannelError.slowDown(let seconds) {
                try? await Task.sleep(for: .seconds(seconds))
            } catch {
                // iCloud unreachable for now; the next pass tries again.
            }
            let until = clock().addingTimeInterval(pollInterval)
            repeat {
                try? await Task.sleep(for: .seconds(min(0.1, pollInterval)))
                await tick()
            } while clock() < until && !Task.isCancelled
        }
    }

    /// Remove frames nobody read, in every zone (FR-017).
    public func sweep(olderThan age: TimeInterval = 24 * 3600) async {
        try? await channel.sweep(olderThan: clock().addingTimeInterval(-age))
    }
}
#endif
