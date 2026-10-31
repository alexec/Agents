// Not on Linux: the relay is iCloud's, and a Mac's (037, 046).
#if canImport(CryptoKit)
import AgentsKitCore
import ControlDial
import Foundation

/// `agents-relay` (058, T096–T097): a Mac's helper that carries the person's devices
/// through iCloud to their control plane, and posts their notices.
///
/// It enrols with a host code, as a host that only relays, and keeps one uplink. The
/// control plane opens no client channels on it; on channel 0 it says which devices may
/// be carried for (`relay/devices`) and what to post (`relay/deliver`).
///
/// A device's relayed session is a WebSocket of its own to the control plane's address,
/// dialled here with the pin; every line is carried untouched, the key exchange first, so
/// the device proves itself to the control plane end to end and this sees nothing but
/// what the control plane would show that device. Frames are sealed between the device
/// and this relay's key, which is its host key: the key `control/status` names.
public final class ControlRelay: @unchecked Sendable {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The membership and key, in the relay's own folder.
    public struct Files: Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
        public var membership: URL { folder.appendingPathComponent("relay-host.json") }
        public var key: URL { folder.appendingPathComponent("relay-key") }
        /// A one-time host code Agents Host leaves before it starts the relay (#809), read
        /// in place of `--join` until the relay has joined, and removed once it has.
        public var joinCode: URL { folder.appendingPathComponent("relay-join-code") }
    }

    public typealias Dial = @Sendable (URL, String?) async throws -> any LineTransport

    private let files: Files
    private let membership: ControlMembership
    private let privateKey: Data
    private let channel: any RelayChannel
    private let mailbox: any Mailbox
    private let dial: Dial
    private let log: @Sendable (String) -> Void
    public let core: RelayHostCore
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var uplink: (any LineTransport)?
    private let stopped = ManagedAtomicFlag()
    private let hello: DaemonAPI.MachineHello
    private var mailboxReady = false
    private var carrying: [UUID: Data]?
    /// The uplink's waits between dials, jittered and cut short by a wake or a network
    /// change (#172), as `ControlUplink`'s are.
    private let backoff: Backoff
    /// Notices that did not post, and the waits between tries at them (#172).
    private var pending = PendingPosts()
    private let retryBackoff: Backoff
    private var retrying: Task<Void, Never>?
    /// The last count for each device (#1163), so a retry never posts an older one.
    private var latestCount: [UUID: MailboxCount] = [:]

    /// Enrol with a host code, once: what the relay keeps to dial again.
    @discardableResult
    public static func enroll(_ code: ControlCode, files: Files, name: String) async throws -> ControlMembership {
        let key = try ControlAgreement.loadOrMake(file: files.key)
        let membership = try await ControlJoin.enrollHost(code, privateKey: key, hello: hello(name: name))
        try membership.save(files.membership)
        return membership
    }

    /// Switch this relay on or off at its control plane, by its own word (`relay/switch`,
    /// #824): over its membership, as its uplink dials, so no control plane's key is
    /// needed. Agents Host has it said under Join one elsewhere. Returns once the control
    /// plane answers; throws what it refused, or when it could not be reached.
    public static func switchRelay(_ on: Bool, files: Files, name: String,
                                   within limit: Duration = .seconds(20)) async throws {
        guard let membership = ControlMembership.load(files.membership), membership.host != nil else {
            throw Failure("this relay has not joined a control plane")
        }
        let key = try ControlAgreement.loadOrMake(file: files.key)
        let dial = try ControlJoin.hostDial(membership, privateKey: key)
        let open = OpenTransport()
        let timer = Task {
            try await Task.sleep(for: limit)
            open.close()
        }
        defer { timer.cancel(); open.close() }
        let transport = try await dial()
        open.set(transport)
        for (id, method, params) in [(1, DaemonAPI.Method.hostHello, try JSONValue.encoding(hello(name: name))),
                                     (2, DaemonAPI.Method.relaySwitch, try JSONValue.encoding(DaemonAPI.RelaySwitch(relay: on)))] {
            let line = try JSONRPCCodec.encode(.request(id: .number(id), method: method, params: params))
            try transport.write(line: ControlWire.channel(0, message: line))
        }
        do {
            for try await line in transport.lines() {
                guard case .message(0, let message)? = try? ControlWire.readHost(line) else { continue }
                switch try? JSONRPCCodec.decode(line: message) {
                case .success(.number(2), _)?: return
                case .failure(.number(2)?, let error)?: throw Failure(error.message)
                default: continue
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {}
        throw Failure(open.closed ? "the control plane did not answer" : "the control plane went before it answered")
    }

    /// The one-off socket `switchRelay` closes when its time is up.
    private final class OpenTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: (any LineTransport)?
        private var shut = false
        var closed: Bool { lock.withLock { shut } }
        func set(_ transport: any LineTransport) {
            let late = lock.withLock { () -> Bool in
                self.transport = transport
                return shut
            }
            if late { transport.close() }
        }
        func close() {
            let open = lock.withLock { () -> (any LineTransport)? in
                shut = true
                defer { transport = nil }
                return transport
            }
            open?.close()
        }
    }

    static func hello(name: String) -> DaemonAPI.MachineHello {
        DaemonAPI.MachineHello(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev", platform: "macOS relay",
                            machineID: MachineID.current, name: name, relay: true)
    }

    public init(files: Files, name: String, channel: any RelayChannel, mailbox: any Mailbox,
                dial: @escaping Dial = { url, pin in try await ControlDial.connect(url, pin: pin) },
                backoff: Backoff = Backoff(first: ControlUplink.firstWait, longest: ControlUplink.longestWait),
                retryBackoff: Backoff = Backoff(first: .seconds(2), longest: .seconds(300)),
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard let membership = ControlMembership.load(files.membership), membership.host != nil, membership.url != nil else {
            throw Failure("this relay has not joined a control plane; give it a host code")
        }
        self.files = files
        self.membership = membership
        privateKey = try ControlAgreement.loadOrMake(file: files.key)
        self.channel = channel
        self.mailbox = mailbox
        self.dial = dial
        self.backoff = backoff
        self.retryBackoff = retryBackoff
        self.log = log
        hello = Self.hello(name: name)
        core = RelayHostCore(channel: channel, key: try DeviceKey.software(privateKey: privateKey),
                             openDaemon: { throw Failure("a relay has no daemon of its own") })
    }

    /// The key frames and devices seal to: this relay's host key.
    public var publicKey: Data { (try? ControlAgreement.publicKey(privateKey: privateKey)) ?? Data() }

    public func start() async {
        guard !membership.endpointsToDial.isEmpty else { return }
        let dial = self.dial, file = files.membership, log = self.log
        let book = EndpointBook(membership) { newer in
            // The control plane moved or changed its certificate (R16). A save the disk
            // refuses is tried again at the next answer (#212).
            log("relay: the control plane is now at \(newer.url ?? "?")")
            do {
                try newer.save(file)
            } catch {
                log("relay: \(WriteFailure(error, keeping: "the control plane's new address")?.message ?? "could not save the control plane's new address: \(error)")")
                throw error
            }
        }
        // A device's session: a socket of its own to the control plane, nothing proved
        // on it here. The device's first line is its answer to the control plane's hello.
        // It goes where the relay's own uplink last got an answer.
        await core.setOpenDevice { _ in
            var last: any Error = Failure("the control plane has no address")
            for endpoint in book.order {
                guard let url = URL(string: endpoint.url) else { continue }
                do { return try await dial(url, endpoint.pin) } catch { last = error }
            }
            throw last
        }
        let hostDial = try? ControlJoin.hostDial(book, privateKey: privateKey)
        let carrying = Task { [core] in await core.run() }
        let sweeping = Task { [core] in
            while !Task.isCancelled {
                await core.sweep()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        let uplinking = Task { [weak self] in
            guard let hostDial else { return }
            await self?.runUplink(hostDial)
        }
        lock.withLock { tasks = [carrying, sweeping, uplinking] }
    }

    public func stop() {
        guard stopped.set() else { return }
        let (running, open) = lock.withLock { () -> ([Task<Void, Never>], (any LineTransport)?) in
            defer { tasks = []; uplink = nil; retrying = nil }
            return (tasks + (retrying.map { [$0] } ?? []), uplink)
        }
        for task in running { task.cancel() }
        open?.close()
    }

    // MARK: The uplink

    /// The network changed or the Mac woke: a wait between dials ends now (#172, as #82
    /// did for `ControlUplink`), and so does a wait before posting again.
    @discardableResult
    public func goBackNow() -> Backoff.Nudged {
        retryBackoff.nudge()
        return backoff.nudge()
    }

    private func runUplink(_ hostDial: @escaping @Sendable () async throws -> any LineTransport) async {
        while !stopped.isSet && !Task.isCancelled {
            backoff.trying()
            do {
                let transport = try await hostDial()
                backoff.connected()
                lock.withLock { uplink = transport }
                let line = try JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.hostHello,
                                                            params: try JSONValue.encoding(hello)))
                try transport.write(line: ControlWire.channel(0, message: line))
                log("relay: connected to \(membership.name)")
                do {
                    for try await line in transport.lines() { await heard(line, on: transport) }
                } catch {}
                transport.close()
                lock.withLock { uplink = nil }
                log("relay: the control plane went")
            } catch {
                log("relay: could not reach the control plane: \(error)")
            }
            guard !stopped.isSet else { return }
            await backoff.wait()
        }
    }

    private func heard(_ line: String, on transport: any LineTransport) async {
        guard let frame = try? ControlWire.readHost(line) else { return }
        switch frame {
        case .message(0, let message):
            guard case .notification(let method, let params)? = try? JSONRPCCodec.decode(line: message) else { return }
            switch method {
            case DaemonAPI.Method.relayDevices:
                guard let list = try? params?.decode(DaemonAPI.RelayDevices.self) else { return }
                let devices = Dictionary(list.devices.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { $1 })
                await core.setPaired(devices)
                let changed = lock.withLock { () -> Bool in
                    defer { carrying = devices }
                    return carrying != devices
                }
                if changed { log("relay: carrying for \(devices.count) devices") }
            case DaemonAPI.Method.relayDeliver:
                guard let delivery = try? params?.decode(DaemonAPI.RelayDelivery.self) else { return }
                await deliver(delivery)
            case DaemonAPI.Method.relayCount:
                guard let count = try? params?.decode(DaemonAPI.RelayCount.self) else { return }
                await deliver(count)
            default:
                return
            }
        case .open, .message, .close, .fanOut:
            // A relay runs nothing for a client, and a channel the control plane opened
            // by mistake is left unanswered rather than closed: closing it would end the
            // client's whole connection.
            return
        }
    }

    // MARK: Notices (T097)

    /// Seal the headline to the device the control plane chose, and post it; or post the
    /// withdrawal. What to send and to whom is the control plane's; only the key is here.
    public func deliver(_ delivery: DaemonAPI.RelayDelivery) async {
        var envelope: Envelope?
        if let headline = delivery.headline {
            guard let key = delivery.publicKey, let sealed = try? Envelope.seal(headline, to: key) else {
                log("relay: could not seal a need for \(delivery.device)")
                return
            }
            envelope = sealed
        }
        let item = MailboxItem(needID: delivery.needID, device: delivery.device, envelope: envelope,
                               alert: delivery.alert, postedAt: Date(), waiting: delivery.waiting)
        do {
            try await post(item)
            log("relay: posted \(envelope == nil ? "a withdrawal" : "a need") for \(delivery.device)")
        } catch {
            log("relay: posting failed, kept to post again: \(error)")
            keepToPostAgain(item)
        }
    }

    /// One device's Needs you count (#1163), posted in place of the last. One that fails
    /// is posted again once, a while later, unless a newer count has come meanwhile: the
    /// next move of the count posts it anyway.
    public func deliver(_ count: DaemonAPI.RelayCount) async {
        let item = MailboxCount(device: count.device, waiting: count.waiting, countedAt: count.countedAt)
        lock.withLock { latestCount[count.device] = item }
        do {
            try await prepareMailbox()
            try await mailbox.post(item)
            log("relay: posted a count for \(count.device)")
        } catch {
            log("relay: posting a count failed, trying again soon: \(error)")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.lock.withLock({ self.latestCount[count.device] == item }) else { return }
                try? await self.mailbox.post(item)
            }
        }
    }

    /// Notices waiting to be posted again, for tests.
    public var waitingToPost: [MailboxItem] { lock.withLock { pending.waiting } }

    private func post(_ item: MailboxItem) async throws {
        try await prepareMailbox()
        try await mailbox.post(item)
        lock.withLock { pending.posted(item) }
    }

    /// Kept, and one loop posts everything kept, waiting longer after each round that
    /// failed, until nothing is left (#172).
    private func keepToPostAgain(_ item: MailboxItem) {
        let dropped = lock.withLock { () -> MailboxItem? in
            let dropped = pending.keep(item)
            if retrying == nil, !stopped.isSet { retrying = Task { [weak self] in await self?.postAgain() } }
            return dropped
        }
        if let dropped { log("relay: too many notices waiting; let go of one for \(dropped.device)") }
    }

    private func postAgain() async {
        let backoff = retryBackoff
        backoff.trying()
        while !Task.isCancelled, !stopped.isSet {
            await backoff.wait()
            for item in lock.withLock({ pending.waiting }) {
                guard let current = lock.withLock({ pending.current(item) }) else { continue }
                do {
                    try await post(current)
                    log("relay: posted again for \(current.device)")
                } catch {
                    log("relay: posting again failed: \(error)")
                    break
                }
            }
            let done = lock.withLock { () -> Bool in
                guard pending.isEmpty else { return false }
                retrying = nil
                return true
            }
            if done { break }
        }
        backoff.settle()
    }

    private func prepareMailbox() async throws {
        guard !lock.withLock({ mailboxReady }) else { return }
        if let prepared = mailbox as? any PreparedMailbox { try await prepared.prepare() }
        lock.withLock { mailboxReady = true }
    }
}

/// A mailbox with something to set up before its first post: CloudKit's zone and
/// subscription.
public protocol PreparedMailbox: Mailbox {
    func prepare() async throws
}

extension CloudKitMailbox: PreparedMailbox {}
#endif
