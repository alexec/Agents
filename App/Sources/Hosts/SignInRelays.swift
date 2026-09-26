import AgentsKit
import Foundation

/// The sign-ins this Mac relays to its servers (047, research R12): one relay per runtime
/// that has one (Codex's ChatGPT sign-in), started the first time a server connects while
/// this Mac is signed in, and shared by every server after that.
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

    /// The Mac's own sign-in file for `runtimeID`, when its policy relays one.
    static func signIn(for runtimeID: String) -> MacSignIn? {
        guard let relay = ToolPolicyCatalog.policy(for: runtimeID).relay else { return nil }
        return MacSignIn(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relay.macSignIn))
    }

    /// Whether this Mac can relay `runtimeID`'s sign-in right now: it is signed in the way
    /// the relay lends (a ChatGPT sign-in, for Codex).
    static func canRelay(_ runtimeID: String) -> Bool {
        signIn(for: runtimeID)?.isSignedIn ?? false
    }

    /// What a server is offered for Codex, or nil when this Mac is not signed in to lend it.
    func grant() async -> ServerConnection.RelayGrant? {
        let runtimeID = RuntimeCatalog.codex.id
        guard let policy = ToolPolicyCatalog.policy(for: runtimeID).relay,
              let signIn = Self.signIn(for: runtimeID), signIn.isSignedIn else { return nil }
        let relay = relay(for: runtimeID, policy: policy, signIn: signIn)
        do {
            let port = try await relay.start()
            return ServerConnection.RelayGrant(runtime: runtimeID, localPort: port,
                                               caCertificate: try relay.certificates.caPEM(),
                                               standIn: try signIn.standIn())
        } catch {
            write("relay for \(runtimeID) could not start: \(error)")
            return nil
        }
    }

    func stop() {
        lock.lock()
        let all = relays.values
        relays = [:]
        lock.unlock()
        for relay in all { relay.stop() }
    }

    private func relay(for runtimeID: String, policy: SignInRelay, signIn: MacSignIn) -> MacSignInRelay {
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
