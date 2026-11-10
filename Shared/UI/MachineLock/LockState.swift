import AgentsKitCore
import Foundation
import Observation

/// What a client keeps of the machine lock (#3490, `specs/3399-machine-lock` D1, D2): its own
/// place in the lock, and the other clients that ask to join it. The window's model and the
/// Remote's each own one, beside `SignInState`, and feed it from the control plane's own
/// connection: `connected` when it answers, `heard` for each notification, `went` when it
/// goes. The web page's is `Web/src/model/machineLock.ts`.
///
/// At each connection the client reads the lock. With none, it signs the root (trust on first
/// use). With one that does not name its key, it asks to join: it sends a commitment to its
/// key and a nonce, and shows its nonce only once a signer sent one, so both screens show six
/// digits that the control plane cannot choose. A client in the lock is a signer: it shows a
/// card for each client that asks, and approves one by signing its addClient.
///
/// Machines (#3491, D3, D8): a machine that asks is shown the same way and approved with an
/// addMachine; a host code made here carries an invite this client put on the lock; and a
/// secret is sealed only to a machine whose key its owner's lock names.
///
/// This Mac's own host (#4248): the window that makes the root puts an invite for it in the
/// same lock/add and keeps it in the host's root, as a join code would, so the host adds
/// itself and nobody compares digits between two parts of one app.
@MainActor @Observable
final class LockState {
    /// This device's place in the lock.
    enum Place: Equatable {
        /// Not read yet, or a control plane that has no lock.
        case unknown
        case member
        /// Asked to join; the digits once a signer sent its nonce.
        case asking(request: String, digits: String?)
        /// The request ended with no approval: Ask Again.
        case ended(denied: Bool)
        /// The lock does not check: nothing is signed.
        case broken(MachineLock.Failure)
    }

    /// Where a signer's card stands.
    enum Step: Equatable {
        /// Nobody compares yet: Compare Digits.
        case waiting
        /// Another of the person's devices sent its nonce.
        case elsewhere
        /// This device sent its nonce; the other has not shown its own yet.
        case revealing
        /// Both nonces: the digits to compare.
        case compare(String)
        /// The asking client's nonce is not the one it committed to.
        case mismatch
    }

    /// The recovery key's card on a device in the lock (#3493, D4).
    enum RecoveryCard: Equatable {
        case none
        /// Shown once, just after it was made.
        case show(String)
        /// The lock has one client and a machine that is not this Mac's own host, and the
        /// person neither saved nor skipped a key here.
        case offer
    }

    private(set) var place: Place = .unknown
    /// The recovery key made here, kept only in memory until the person saved or skipped it.
    private var recoveryShown: String?
    /// This Mac's own host, on the Mac window only (#4248): its id, and where its invite goes.
    struct OwnHost {
        var id: () -> String?
        var keepInvite: (_ invite: Data, _ pin: MachineLock.Pin) throws -> Void
    }
    var ownHost: OwnHost?
    /// The own host's id, read at each connection: the recovery card leaves it out.
    private var ownHostID: String?
    /// A recovery step in flight: Make Recovery Key, Use, or Start a New Lock.
    private(set) var recoveryBusy = false
    /// The lock as this device last checked it, kept with the pin so a channel to a machine
    /// opens before the control plane answers, and with it away (#3492).
    private(set) var checked: MachineLock.State?
    /// The control plane answered and the lock was read, or it has none.
    private var settled = false
    private(set) var requests: [DaemonAPI.LockJoinRequest] = []
    /// Requests answered from here and not decided yet: their buttons wait.
    private(set) var answering: Set<String> = []
    /// Why the last answer from here failed, by request.
    private(set) var failures: [String: String] = [:]

    private var client: String?
    private var key: LockSigningKey?
    /// This device's own nonce, for its open request.
    private var ownNonce: Data?
    /// The nonce this device sent, by request: the digits use it, never the one sent back.
    private var signerNonces: [String: Data] = [:]
    private let pins: LockPins
    private let name: String
    private let kind: ClientRecord.Kind
    private let account: String

    init(pins: LockPins, name: String, kind: ClientRecord.Kind, account: String) {
        self.pins = pins
        self.name = name
        self.kind = kind
        self.account = account
        if let lock = pins.loadLock(), let state = try? MachineLock.follow(pins.load(), lock) { checked = state }
    }

    /// This device's lock key and its checked lock, for the channels it opens to machines
    /// (#3492, D6); nil when it is not in its lock, and then it talks to machines as before.
    /// With no lock kept yet, it waits a little for the control plane's.
    func channelSigner() async -> LockChannel.Signer? {
        for _ in 0..<50 where checked == nil && !settled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let state = checked, let key = signingKey(), state.members[key.publicKey]?.isClient == true else { return nil }
        return LockChannel.Signer(key: key, state: state)
    }

    /// Takes a lock this device checked: kept, with its pin.
    private func took(_ state: MachineLock.State, _ lock: DaemonAPI.Lock) {
        checked = state
        pins.save(state.pin)
        pins.saveLock(lock)
    }

    /// The recovery key's card now: the key just made, or an offer to make one while the lock
    /// has only this client (a key shown before is gone once the app closes). With nothing in
    /// the lock but this device and its own host there is nothing a key could get back, so the
    /// offer waits for another machine (#4248); another client is a way back of its own (D4).
    var recoveryCard: RecoveryCard {
        guard place == .member, let state = checked else { return .none }
        if let recoveryShown { return .show(recoveryShown) }
        let clients = state.members.values.filter(\.isClient).count
        let machines = state.members.values.contains { $0.kind == .addMachine && $0.id != ownHostID }
        return clients <= 1 && machines && !pins.recoveryDone(state.person) ? .offer : .none
    }

    /// I Saved It, or Skip: not asked again on this device.
    func dismissRecovery() {
        if let person = checked?.person { pins.setRecoveryDone(person) }
        recoveryShown = nil
    }

    /// Make Recovery Key: a new recovery entry, which takes the old key's place, shown once.
    func makeRecoveryKey(on control: DaemonClient?) async {
        guard let control, !recoveryBusy else { return }
        recoveryBusy = true
        defer { recoveryBusy = false }
        guard let made = try? MachineLock.makeRecovery() else { return }
        let body = DaemonAPI.LockBody(kind: .recovery, person: "", key: made.publicKey, sealed: made.sealed)
        guard let after = try? await put(body, on: control) else { return }
        checked = after
        recoveryShown = made.text
    }

    /// Use Recovery Key (#3493, D4): this device, not in its lock, opens the lock's recovery key
    /// with the secret the person typed and signs its own addClient with it. Nil when it is in;
    /// else the words to show under the field.
    func useRecoveryKey(_ text: String, on control: DaemonClient?) async -> String? {
        guard let control else { return LockWords.unreachable }
        guard !recoveryBusy else { return nil }
        recoveryBusy = true
        defer { recoveryBusy = false }
        let secret: Data
        do { secret = try MachineLock.parseRecovery(text) } catch { return LockWords.recoveryTypo }
        guard let key = signingKey() else { return LockWords.recoveryFailed }
        for attempt in 0..<2 {
            guard let lock = try? await control.call(DaemonAPI.Method.lockGet, DaemonAPI.LockGet(), returning: DaemonAPI.Lock.self),
                  let state = try? MachineLock.follow(pins.load(), lock) else { return LockWords.recoveryFailed }
            guard let public_ = state.recovery, let sealed = state.recoverySealed else { return LockWords.noRecovery }
            let recovery: LockSigningKey
            do { recovery = try MachineLock.openRecovery(secret, publicKey: public_, sealed: sealed) } catch { return LockWords.recoveryNotThisLock }
            let body = DaemonAPI.LockBody(kind: .addClient, person: "", key: key.publicKey, id: client, name: name,
                                         clientKind: MachineLock.clientKind(kind))
            do {
                let entry = try MachineLock.sign(body, after: state, with: recovery)
                _ = try await control.call(DaemonAPI.Method.lockAdd, DaemonAPI.LockAdd(entries: [entry]), returning: DaemonAPI.LockHead.self)
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.changedElsewhere && attempt == 0 {
                continue
            } catch {
                return PeopleWords.refusal(error)
            }
            ownNonce = nil
            place = .unknown
            await refresh(control)
            return nil
        }
        return LockWords.recoveryFailed
    }

    /// Start a New Lock (#3493, D4): every signer and the recovery key are lost. The control plane
    /// drops the lock, this device forgets its pin and signs a new root with a new recovery key.
    /// Each machine joins again after agentsd lock reset.
    func startNewLock(on control: DaemonClient?) async {
        guard let control, !recoveryBusy else { return }
        recoveryBusy = true
        defer { recoveryBusy = false }
        guard (try? await control.call(DaemonAPI.Method.lockReset, DaemonAPI.Empty())) != nil else { return }
        pins.clear()
        checked = nil
        ownNonce = nil
        place = .unknown
        await refresh(control)
    }

    /// The cards to show now: other clients' open requests.
    func open(at now: Date = Date()) -> [DaemonAPI.LockJoinRequest] {
        guard place == .member else { return [] }
        return requests.filter { $0.expires > now && $0.client != client }
    }

    func step(_ request: DaemonAPI.LockJoinRequest) -> Step {
        guard request.nonce != nil else { return .waiting }
        guard request.answeredBy == client, let mine = signerNonces[request.request] else { return .elsewhere }
        guard let reveal = request.reveal else { return .revealing }
        guard MachineLock.commitment(key: request.key, nonce: reveal) == request.commitment else { return .mismatch }
        return .compare(MachineLock.digits(key: request.key, clientNonce: reveal, signerNonce: mine))
    }

    /// The control plane answered. One with no lock does not know the methods: nothing shows.
    func connected(_ control: DaemonClient, client: UUID) async {
        self.client = client.uuidString
        ownHostID = ownHost?.id()
        pins.pruneOthers()
        await refresh(control)
        settled = true
        let listed = try? await control.call(DaemonAPI.Method.lockJoinRequests, DaemonAPI.Empty(),
                                             returning: [DaemonAPI.LockJoinRequest].self)
        requests = listed ?? []
    }

    /// A notification from the control plane. True when it was one of the lock's.
    func heard(_ method: String, _ params: JSONValue?, on control: DaemonClient) async -> Bool {
        switch method {
        case DaemonAPI.Notification.controlLockChanged:
            // A member reads it too: the machines it opens channels to are in it (#3492).
            await refresh(control)
        case DaemonAPI.Notification.controlLockJoinRequested:
            guard let request = try? params?.decode(DaemonAPI.LockJoinRequest.self) else { return true }
            if let index = requests.firstIndex(where: { $0.request == request.request }) {
                requests[index] = request
            } else {
                requests.append(request)
            }
            await answerOwn(request, on: control)
        case DaemonAPI.Notification.controlLockJoinDecided:
            guard let decided = try? params?.decode(DaemonAPI.LockJoinDecided.self) else { return true }
            requests.removeAll { $0.request == decided.request }
            answering.remove(decided.request)
            signerNonces[decided.request] = nil
            failures[decided.request] = nil
            if case .asking(let request, _) = place, request == decided.request {
                ownNonce = nil
                if decided.result == "approved" {
                    await refresh(control)
                } else {
                    place = .ended(denied: decided.result == "denied")
                }
            }
        default:
            return false
        }
        return true
    }

    /// The control plane went: nothing can be answered until it is back.
    func went() {
        requests = []
        answering = []
        signerNonces = [:]
    }

    /// Ask Again, after a request ended.
    func askAgain(on control: DaemonClient?) async {
        guard let control else { return }
        await refresh(control)
    }

    /// Compare Digits on a card: this device's nonce.
    func compare(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient?) async {
        await answering(request, on: control) { control in
            let nonce = MachineLock.nonce()
            self.signerNonces[request.request] = nonce
            do {
                _ = try await control.call(DaemonAPI.Method.lockJoinAnswer, DaemonAPI.LockJoinNonce(request: request.request, nonce: nonce))
            } catch {
                self.signerNonces[request.request] = nil
                throw error
            }
        }
    }

    /// Approve: the client's addClient, or the machine's addMachine, signed here, on the lock.
    /// A machine's key is also its sealing key (D8).
    func approve(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient?) async {
        guard case .compare = step(request) else { return }
        await answering(request, on: control) { control in
            let body = if let machine = request.machine {
                DaemonAPI.LockBody(kind: .addMachine, person: "", key: request.key, sealingKey: request.key, id: machine, name: request.name)
            } else {
                DaemonAPI.LockBody(kind: .addClient, person: "", key: request.key, id: request.client, name: request.name,
                                   clientKind: MachineLock.clientKind(request.kind))
            }
            try await self.put(body, on: control)
        }
    }

    /// A host code with an invite (#3491, D3): this client puts an invite on the lock and adds
    /// its key to the code, so the machine adds itself. A client that is not a signer gives the
    /// code back as it was: the machine then asks to join.
    func invite(_ shown: DaemonAPI.ControlCodeShown, on control: DaemonClient) async -> DaemonAPI.ControlCodeShown {
        guard let key = signingKey() else { return shown }
        return await Self.invite(shown, on: control, pins: pins, key: key)
    }

    /// `invite` for a caller with no `LockState` of its own: Add a Machine, on its own
    /// connection. A control plane with no lock, or no signing key, gives the code back.
    static func invite(_ shown: DaemonAPI.ControlCodeShown, on control: DaemonClient, pins: LockPins,
                       account: String) async -> DaemonAPI.ControlCodeShown {
        guard let key = try? LockSigningKey.load(account: account) else { return shown }
        return await invite(shown, on: control, pins: pins, key: key)
    }

    static func invite(_ shown: DaemonAPI.ControlCodeShown, on control: DaemonClient, pins: LockPins,
                       key: LockSigningKey) async -> DaemonAPI.ControlCodeShown {
        let invite = MachineLock.inviteKey()
        let body = DaemonAPI.LockBody(kind: .invite, person: "", key: invite.publicKey.x963Representation,
                                      expires: Date().addingTimeInterval(inviteLifetime))
        guard let after = try? await put(body, on: control, pins: pins, key: key, signerOnly: true) else { return shown }
        let text = MachineLock.inviteCode(shown.text, invite: invite.rawRepresentation, pin: after.pin)
        return DaemonAPI.ControlCodeShown(text: text, expires: shown.expires,
                                          command: shown.command?.replacingOccurrences(of: shown.text, with: text))
    }

    /// An invite works for five minutes, as a code does (D3).
    static let inviteLifetime: TimeInterval = 5 * 60

    /// The recipients this client may seal to (#3491, D8): every client, and each machine whose
    /// key its owner's lock names. Another person's lock is pinned here too, on first use.
    func signed(_ recipients: [DaemonAPI.SealRecipient], on control: DaemonClient) async -> [DaemonAPI.SealRecipient] {
        let pins = pins
        let own = try? await control.call(DaemonAPI.Method.lockGet, DaemonAPI.LockGet(), returning: DaemonAPI.Lock.self)
        let ownState = own.flatMap { try? MachineLock.follow(pins.load(), $0) }
        if let ownState { pins.save(ownState.pin) }
        return await MachineLock.signedRecipients(recipients) { person in
            guard let person, person != ownState?.person else { return ownState }
            let theirs = LockPins(defaults: pins.defaults, name: "\(pins.name):\(person)")
            guard let lock = try? await control.call(DaemonAPI.Method.lockGet, DaemonAPI.LockGet(person: person), returning: DaemonAPI.Lock.self),
                  let state = try? MachineLock.follow(theirs.load(), lock) else { return nil }
            theirs.save(state.pin)
            return state
        }
    }

    /// Deny on a card.
    func deny(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient?) async {
        await answering(request, on: control) { control in
            _ = try await control.call(DaemonAPI.Method.lockJoinDeny, DaemonAPI.LockJoinEnd(request: request.request))
            self.requests.removeAll { $0.request == request.request }
        }
    }

    private func answering(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient?,
                           _ act: (DaemonClient) async throws -> Void) async {
        guard let control else {
            failures[request.request] = LockWords.unreachable
            return
        }
        guard answering.insert(request.request).inserted else { return }
        defer { answering.remove(request.request) }
        do {
            try await act(control)
            failures[request.request] = nil
        } catch {
            failures[request.request] = PeopleWords.refusal(error)
        }
    }

    /// Reads the lock and takes this device's place in it.
    private func refresh(_ control: DaemonClient) async {
        guard let key = signingKey() else { return }
        guard let lock = try? await control.call(DaemonAPI.Method.lockGet, DaemonAPI.LockGet(), returning: DaemonAPI.Lock.self) else { return }
        if lock.entries.isEmpty {
            let root = DaemonAPI.LockBody(kind: .root, person: lock.person, key: key.publicKey, id: client, name: name,
                                          clientKind: MachineLock.clientKind(kind))
            // Another device may make the root at the same moment: then this one asks to join it.
            do {
                try await putRoot(root, on: control, key: key)
                return await refresh(control)
            } catch LockTrouble.changed {
                return await refresh(control)
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.changedElsewhere {
                return await refresh(control)
            } catch {
                return
            }
        }
        let state: MachineLock.State
        do {
            state = try MachineLock.follow(pins.load(), lock)
        } catch {
            place = .broken(error)
            return
        }
        took(state, lock)
        if state.members[key.publicKey]?.isClient == true {
            place = .member
            return
        }
        if case .asking = place { return }
        let nonce = MachineLock.nonce()
        let ask = DaemonAPI.LockJoin(key: key.publicKey, commitment: MachineLock.commitment(key: key.publicKey, nonce: nonce))
        guard let started = try? await control.call(DaemonAPI.Method.lockJoin, ask, returning: DaemonAPI.LockJoinStarted.self) else { return }
        ownNonce = nonce
        place = .asking(request: started.request, digits: nil)
    }

    /// The root, and in the same lock/add an invite for this Mac's own host (#4248, D3). The
    /// invite is kept in the host's root before the lock is sent, so the host has it when the
    /// control plane sends the lock; when it cannot be kept, the host asks to join as before.
    /// No recovery key yet: the card offers one once another machine joins.
    private func putRoot(_ root: DaemonAPI.LockBody, on control: DaemonClient, key: LockSigningKey) async throws {
        let rootEntry = try MachineLock.sign(root, after: nil, with: key)
        var state = MachineLock.State()
        try state.add(rootEntry)
        var entries = [rootEntry]
        if let ownHost {
            let invite = MachineLock.inviteKey()
            let body = DaemonAPI.LockBody(kind: .invite, person: state.person, key: invite.publicKey.x963Representation,
                                          expires: Date().addingTimeInterval(Self.inviteLifetime))
            let entry = try MachineLock.sign(body, after: state, with: key)
            var after = state
            try after.add(entry)
            if (try? ownHost.keepInvite(invite.rawRepresentation, after.pin)) != nil { entries.append(entry) }
        }
        _ = try await control.call(DaemonAPI.Method.lockAdd, DaemonAPI.LockAdd(entries: entries),
                                   returning: DaemonAPI.LockHead.self)
        place = .member
    }

    /// This device's own request, once a signer sent its nonce: show ours, and the digits.
    private func answerOwn(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient) async {
        guard case .asking(let id, let digits) = place, id == request.request, digits == nil,
              let signer = request.nonce, let ownNonce, let key else { return }
        guard (try? await control.call(DaemonAPI.Method.lockJoinReveal, DaemonAPI.LockJoinNonce(request: id, nonce: ownNonce))) != nil else { return }
        place = .asking(request: id, digits: MachineLock.digits(key: key.publicKey, clientNonce: ownNonce, signerNonce: signer))
    }

    /// Signs `body` onto the lock as it is now, read and checked here; once more when another
    /// device put an entry first.
    @discardableResult
    private func put(_ body: DaemonAPI.LockBody, on control: DaemonClient, first: Bool = false) async throws -> MachineLock.State {
        guard let key = signingKey() else { throw LockTrouble.noKey }
        let after = try await Self.put(body, on: control, pins: pins, key: key, first: first)
        if first { place = .member }
        return after
    }

    /// `put` with the pins and key given: the lock after the entry. `signerOnly` refuses when
    /// the key is not a signer of the lock as it is (an invite from a client still asking).
    @discardableResult
    private static func put(_ body: DaemonAPI.LockBody, on control: DaemonClient, pins: LockPins, key: LockSigningKey,
                            first: Bool = false, signerOnly: Bool = false) async throws -> MachineLock.State {
        for attempt in 0..<2 {
            let lock = try await control.call(DaemonAPI.Method.lockGet, DaemonAPI.LockGet(), returning: DaemonAPI.Lock.self)
            if first, !lock.entries.isEmpty { throw LockTrouble.changed }
            let state = lock.entries.isEmpty ? nil : try MachineLock.follow(pins.load(), lock)
            if signerOnly, state?.isSigner(key.publicKey) != true { throw LockTrouble.noKey }
            let entry = try MachineLock.sign(body, after: state, with: key)
            do {
                let head = try await control.call(DaemonAPI.Method.lockAdd, DaemonAPI.LockAdd(entries: [entry]),
                                                  returning: DaemonAPI.LockHead.self)
                var after = state ?? MachineLock.State()
                try after.add(entry)
                if after.head == head.head { pins.save(after.pin) }
                return after
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.changedElsewhere && attempt == 0 && !first {
                continue
            }
        }
        throw LockTrouble.changed
    }

    private func signingKey() -> LockSigningKey? {
        if let key { return key }
        key = try? LockSigningKey.load(account: account)
        return key
    }

    enum LockTrouble: Error { case noKey, changed }
}

/// Where a client keeps the pin of the lock it last checked: not a secret, so in defaults.
struct LockPins {
    var defaults: UserDefaults
    var name: String

    func load() -> MachineLock.Pin? {
        defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(MachineLock.Pin.self, from: $0) }
    }

    func save(_ pin: MachineLock.Pin) {
        if let data = try? JSONEncoder().encode(pin) { defaults.set(data, forKey: name) }
    }

    /// The whole lock last checked (#3492), beside its pin.
    func loadLock() -> DaemonAPI.Lock? {
        defaults.data(forKey: name + ".lock").flatMap { try? JSONDecoder().decode(DaemonAPI.Lock.self, from: $0) }
    }

    func saveLock(_ lock: DaemonAPI.Lock) {
        if let data = try? JSONEncoder().encode(lock) { defaults.set(data, forKey: name + ".lock") }
    }

    /// Forgets the lock, for a new one (#3493): the next lock read is taken on first use.
    func clear() {
        defaults.removeObject(forKey: name)
        defaults.removeObject(forKey: name + ".lock")
    }

    /// Forgets everything kept under this name (#3670): the pin, the lock, each person's pin
    /// and lock, and whether each saved the recovery key. For a Forget of the control plane.
    func clearAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key == name || key.hasPrefix(name + ".") || key.hasPrefix(name + ":") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Forgets the pins kept for another control plane than this name's (#3750): a client
    /// is paired with one at a time.
    func pruneOthers() { ClientDefaults.pruneLockPins(defaults, keeping: name) }

    /// The person saved or skipped the recovery key on this device (#3493).
    func recoveryDone(_ person: String) -> Bool { defaults.bool(forKey: "\(name).recoveryDone.\(person)") }

    func setRecoveryDone(_ person: String) { defaults.set(true, forKey: "\(name).recoveryDone.\(person)") }
}
