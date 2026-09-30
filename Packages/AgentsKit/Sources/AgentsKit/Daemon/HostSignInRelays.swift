#if canImport(Network) && canImport(Security)
import AgentsKitCore
import Foundation

/// The sign-ins this Mac's host relays (058, T091; 047 Codex's, 056 Claude's): what the
/// window did while it ran servers over its own ssh, now the Mac host's, since the App Store
/// window may read no keychain item and run no listener.
///
/// One relay per runtime whose policy has one, started on the first grant and kept for the
/// daemon's life. Each listens on this Mac's loopback; a borrowing host reaches it only
/// through a tunnel the control plane opens for a lend an operator allowed.
///
/// A relay's keys and certificates live in `<root>/relay/`; its log, which says only what was
/// asked and how it was answered, is `<root>/hosts/relay.log`.
public final class HostSignInRelays: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    private var relays: [String: MacSignInRelay] = [:]
    private var sources: [String: any MacSignInSource] = [:]

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// This Mac's own sign-in for `runtimeID`, where its policy says it is kept.
    public func signIn(for runtimeID: String) -> (any MacSignInSource)? {
        lock.lock()
        defer { lock.unlock() }
        if let known = sources[runtimeID] { return known }
        guard let relay = ToolPolicyCatalog.policy(for: runtimeID).relay else { return nil }
        let made: any MacSignInSource
        switch relay.macSignIn {
        case .file(let path):
            made = CodexFileSignIn(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path))
        case .keychain(let service):
            // A walk's stand-in item is never renewed: renewing runs the Mac's own
            // `claude`, which would spend a turn on the person's real sign-in.
            if let test = Self.testService {
                made = ClaudeKeychainSignIn(service: test, renewer: {})
            } else {
                made = ClaudeKeychainSignIn(service: service)
            }
        }
        sources[runtimeID] = made
        return made
    }

    /// A walk's stand-in for the Keychain item Claude keeps (056), so a lend can be walked on
    /// a scratch root without reading the person's sign-in. Debug builds only.
    private static var testService: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE"]
        #else
        nil
        #endif
    }

    /// Start relaying `runtimeID`'s sign-in, and say what the borrower's gate needs: the
    /// relay's CA and a stand-in holding no secret of this Mac's. A fresh stand-in each time,
    /// so the one in source is never enough to draw this Mac's token (S4).
    public func grant(_ runtimeID: String) async throws -> DaemonAPI.RelayGrantReply {
        guard let policy = ToolPolicyCatalog.policy(for: runtimeID).relay, let signIn = signIn(for: runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "This Mac does not relay \(runtimeID)'s sign-in.")
        }
        guard signIn.isSignedIn else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                               message: "This Mac is not signed in to \(runtimeID) the way a server can use.")
        }
        let relay = relay(for: runtimeID, policy: policy, signIn: signIn)
        _ = try await relay.start()
        let standIn: String
        switch policy.macSignIn {
        case .keychain: standIn = MacSignInRelay.freshClaudeStandIn()
        case .file: standIn = try signIn.standIn()
        }
        relay.expectClientBearer(MacSignInRelay.clientBearer(fromStandIn: standIn))
        write("granted \(runtimeID) for a tunnel")
        return DaemonAPI.RelayGrantReply(runtime: runtimeID, caCertificate: try relay.certificates.caPEM(), standIn: standIn)
    }

    /// Where the relay for `runtimeID` listens, once granted: what a tunnel connects to.
    public func port(for runtimeID: String) -> UInt16? {
        lock.withLock { relays[runtimeID] }.flatMap { $0.port == 0 ? nil : $0.port }
    }

    public func stop() {
        let all = lock.withLock { () -> [MacSignInRelay] in defer { relays = [:] }; return Array(relays.values) }
        for relay in all { relay.stop() }
    }

    private func relay(for runtimeID: String, policy: SignInRelay, signIn: any MacSignInSource) -> MacSignInRelay {
        lock.lock()
        defer { lock.unlock() }
        if let existing = relays[runtimeID] { return existing }
        let made = MacSignInRelay(relay: policy, signIn: signIn,
                                  certificates: RelayCertificates(folder: locations.root.appendingPathComponent("relay", isDirectory: true)),
                                  log: { [weak self] line in self?.write(line) })
        relays[runtimeID] = made
        return made
    }

    private func write(_ line: String) {
        let file = locations.hostsFolder.appendingPathComponent("relay.log")
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: locations.hostsFolder, withIntermediateDirectories: true)
            try? Data(stamped.utf8).write(to: file)
        }
    }
}
#endif
