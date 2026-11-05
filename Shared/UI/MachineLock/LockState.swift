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

    private(set) var place: Place = .unknown
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
        await refresh(control)
        let listed = try? await control.call(DaemonAPI.Method.lockJoinRequests, DaemonAPI.Empty(),
                                             returning: [DaemonAPI.LockJoinRequest].self)
        requests = listed ?? []
    }

    /// A notification from the control plane. True when it was one of the lock's.
    func heard(_ method: String, _ params: JSONValue?, on control: DaemonClient) async -> Bool {
        switch method {
        case DaemonAPI.Notification.controlLockChanged:
            if place != .member { await refresh(control) }
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

    /// Approve: the client's addClient, signed here, on the lock.
    func approve(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient?) async {
        guard case .compare = step(request) else { return }
        await answering(request, on: control) { control in
            let body = DaemonAPI.LockBody(kind: .addClient, person: "", key: request.key, name: request.name,
                                          clientKind: MachineLock.clientKind(request.kind))
            try await self.put(body, on: control)
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
        guard let lock = try? await control.call(DaemonAPI.Method.lockGet, DaemonAPI.Empty(), returning: DaemonAPI.Lock.self) else { return }
        if lock.entries.isEmpty {
            let root = DaemonAPI.LockBody(kind: .root, person: lock.person, key: key.publicKey, name: name,
                                          clientKind: MachineLock.clientKind(kind))
            // Another device may make the root at the same moment: then this one asks to join it.
            do {
                try await put(root, on: control, first: true)
                return
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
        pins.save(state.pin)
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

    /// This device's own request, once a signer sent its nonce: show ours, and the digits.
    private func answerOwn(_ request: DaemonAPI.LockJoinRequest, on control: DaemonClient) async {
        guard case .asking(let id, let digits) = place, id == request.request, digits == nil,
              let signer = request.nonce, let ownNonce, let key else { return }
        guard (try? await control.call(DaemonAPI.Method.lockJoinReveal, DaemonAPI.LockJoinNonce(request: id, nonce: ownNonce))) != nil else { return }
        place = .asking(request: id, digits: MachineLock.digits(key: key.publicKey, clientNonce: ownNonce, signerNonce: signer))
    }

    /// Signs `body` onto the lock as it is now, read and checked here; once more when another
    /// device put an entry first.
    private func put(_ body: DaemonAPI.LockBody, on control: DaemonClient, first: Bool = false) async throws {
        guard let key = signingKey() else { throw LockTrouble.noKey }
        for attempt in 0..<2 {
            let lock = try await control.call(DaemonAPI.Method.lockGet, DaemonAPI.Empty(), returning: DaemonAPI.Lock.self)
            if first, !lock.entries.isEmpty { throw LockTrouble.changed }
            let state = lock.entries.isEmpty ? nil : try MachineLock.follow(pins.load(), lock)
            let entry = try MachineLock.sign(body, after: state, with: key)
            do {
                let head = try await control.call(DaemonAPI.Method.lockAdd, DaemonAPI.LockAdd(entries: [entry]),
                                                  returning: DaemonAPI.LockHead.self)
                var after = state ?? MachineLock.State()
                try after.add(entry)
                if after.head == head.head { pins.save(after.pin) }
                if first { place = .member }
                return
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
}
