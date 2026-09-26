import AgentsKit
import Foundation

/// The sign-ins this Mac relays to its servers (047 Codex's, 056 Claude's): one relay per
/// runtime whose policy has one, started the first time a server connects while this Mac is
/// signed in, and shared by every server after that.
///
/// A relay's keys and certificates live in `<root>/relay/`; its log, which says only what
/// was asked and how it was answered, is `<root>/hosts/relay.log`.
final class SignInRelays: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    private var relays: [String: MacSignInRelay] = [:]

    init(locations: StoreLocations) {
        self.locations = locations
    }

    /// The runtimes whose sign-in this Mac may relay, in the catalog's order.
    static let relayed: [String] = RuntimeCatalog.builtIn.map(\.id).filter { ToolPolicyCatalog.policy(for: $0).relay != nil }

    private static let sourcesLock = NSLock()
    nonisolated(unsafe) private static var sources: [String: any MacSignInSource] = [:]

    /// This Mac's own sign-in for `runtimeID`, where its policy says it is kept: one source
    /// per runtime for the life of the app, so what a source remembers (056: Claude's cached
    /// read) is shared by every server and by Settings.
    static func signIn(for runtimeID: String) -> (any MacSignInSource)? {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        if let known = sources[runtimeID] { return known }
        guard let relay = ToolPolicyCatalog.policy(for: runtimeID).relay else { return nil }
        let made: (any MacSignInSource)?
        switch relay.macSignIn {
        case .file(let path):
            made = CodexFileSignIn(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path))
        case .keychain:
            made = nil
        }
        sources[runtimeID] = made
        return made
    }

    /// Whether this Mac can relay `runtimeID`'s sign-in right now: it is signed in the way
    /// the relay lends (a ChatGPT sign-in for Codex, a Claude account's for Claude).
    static func canRelay(_ runtimeID: String) -> Bool {
        signIn(for: runtimeID)?.isSignedIn ?? false
    }

    /// What a server is offered: every sign-in this Mac is signed in to lend.
    func grants() async -> [ServerConnection.RelayGrant] {
        var grants: [ServerConnection.RelayGrant] = []
        for runtimeID in Self.relayed {
            guard let policy = ToolPolicyCatalog.policy(for: runtimeID).relay,
                  let signIn = Self.signIn(for: runtimeID), signIn.isSignedIn else { continue }
            let relay = relay(for: runtimeID, policy: policy, signIn: signIn)
            do {
                let port = try await relay.start()
                grants.append(ServerConnection.RelayGrant(runtime: runtimeID, localPort: port,
                                                          caCertificate: try relay.certificates.caPEM(),
                                                          standIn: try signIn.standIn()))
            } catch {
                write("relay for \(runtimeID) could not start: \(error)")
            }
        }
        return grants
    }

    func stop() {
        lock.lock()
        let all = relays.values
        relays = [:]
        lock.unlock()
        for relay in all { relay.stop() }
    }

    private func relay(for runtimeID: String, policy: SignInRelay, signIn: any MacSignInSource) -> MacSignInRelay {
        lock.lock()
        defer { lock.unlock() }
        if let existing = relays[runtimeID] { return existing }
        let folder = locations.root.appendingPathComponent("relay", isDirectory: true)
        let made = MacSignInRelay(relay: policy, signIn: signIn,
                                  certificates: RelayCertificates(folder: folder),
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
