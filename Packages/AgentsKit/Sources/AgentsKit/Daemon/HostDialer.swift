import AgentsKitCore
import ControlDial
import Foundation

/// One dial of a host's uplink (#113): enrolling first with the host code while there is
/// no membership, then dialling as this host with its own key.
///
/// The code is spent only by a join that saved a membership. Until then it stays where
/// Agents Host left it, read again on every try, so a control plane that isn't listening
/// yet, a name that doesn't resolve yet, or a network that blipped is tried again on the
/// uplink's backoff rather than given up after once. A code Agents Host replaces while
/// this waits is the one the next try uses.
public final class HostDialer: @unchecked Sendable {
    public typealias Dial = @Sendable () async throws -> any LineTransport
    public typealias Enroll = @Sendable (ControlCode, Data, DaemonAPI.HostHello) async throws -> ControlMembership
    public typealias MakeDial = @Sendable (ControlMembership, Data, @escaping EndpointBook.Keep) throws -> Dial

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let membershipFile: URL
    private let codeFile: URL
    /// `--control-code`, which wins over a code left in the root.
    private let given: String?
    private let privateKey: Data
    private let hello: DaemonAPI.HostHello
    private let say: @Sendable (DaemonAPI.HostJoinStatus) -> Void
    private let enroll: Enroll
    private let makeDial: MakeDial
    private let lock = NSLock()
    private var ready: Dial?

    public init(membershipFile: URL, codeFile: URL, given: String?, privateKey: Data, hello: DaemonAPI.HostHello,
         say: @escaping @Sendable (DaemonAPI.HostJoinStatus) -> Void,
         enroll: @escaping Enroll = { try await ControlJoin.enrollHost($0, privateKey: $1, hello: $2) },
         makeDial: @escaping MakeDial = { try ControlJoin.hostDial($0, privateKey: $1, keep: $2) }) {
        self.membershipFile = membershipFile
        self.codeFile = codeFile
        self.given = given
        self.privateKey = privateKey
        self.hello = hello
        self.say = say
        self.enroll = enroll
        self.makeDial = makeDial
    }

    /// Whether this host has a membership to dial with.
    public var isMember: Bool { lock.withLock { ready != nil } || ControlMembership.load(membershipFile) != nil }

    /// The uplink's dial. A failure is said, for Agents Host and the window, and thrown
    /// for the uplink to wait and try again.
    public func dial() async throws -> any LineTransport {
        do {
            return try await dialAsMember()()
        } catch {
            let problem = Self.words(for: error)
            let member = isMember
            // The uplink logs every failed dial; this says it is the join that failed.
            if !member { DaemonLog.shared.write("uplink: could not join the control plane yet; the host code is kept") }
            say(.init(member: member, connected: false, problem: problem))
            throw error
        }
    }

    /// The uplink came up or went.
    public func connected(_ up: Bool) {
        say(.init(member: true, connected: up))
    }

    private func dialAsMember() async throws -> Dial {
        if let ready = lock.withLock({ ready }) { return ready }
        let membershipFile = self.membershipFile
        var membership = ControlMembership.load(membershipFile)
        if membership == nil {
            let fromFile = given == nil
            guard let text = given ?? Self.read(codeFile) else {
                throw Failure(description: "there is no host code to join with; ask Agents Host for one")
            }
            guard let code = ControlCode(text: text), code.url != nil else {
                throw Failure(description: "that host code can't be read; ask for a new one")
            }
            let joined = try await enroll(code, privateKey, hello)
            try joined.save(membershipFile)
            // Spent now: a restart dials as this host and never enrols twice.
            if fromFile { try? FileManager.default.removeItem(at: codeFile) }
            DaemonLog.shared.write("uplink: enrolled with \(joined.name) as \(joined.host?.rawValue ?? "?")")
            membership = joined
        }
        guard let membership else { throw Failure(description: "no membership") }
        let made = try makeDial(membership, privateKey) { newer in
            // The control plane moved or changed its certificate (R16).
            try? newer.save(membershipFile)
            DaemonLog.shared.write("uplink: the control plane is now at \(newer.url ?? "?")")
        }
        lock.withLock { ready = made }
        return made
    }

    private static func read(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// A refusal says it in its message, or by its reason; everything else as it describes
    /// itself.
    static func words(for error: any Error) -> String {
        if let error = error as? JSONRPCError { return error.message }
        guard let refusal = error as? ControlAuth.Refusal else { return "\(error)" }
        switch refusal.reason {
        case .expired: return "the host code has run out; Try Again in Agents Host makes a new one"
        case .spent: return "the host code was used already; Try Again in Agents Host makes a new one"
        case .unknown: return "the control plane doesn't know that host code"
        case .forgotten: return "the control plane has forgotten this host"
        case .unavailable: return "the control plane can't read its store just now"
        case .wrongControlPlane: return "something else answers at the control plane's address"
        case .badProof, .badMessage: return "the control plane refused this host (\(refusal.reason.rawValue))"
        }
    }
}
