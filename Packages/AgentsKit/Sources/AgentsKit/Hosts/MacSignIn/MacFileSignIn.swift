import AgentsKitCore
import Foundation

/// A runtime's own sign-in file on this Mac, read for a server run to borrow (049 D7:
/// OpenCode's `auth.json`). Read fresh each time it is lent, and never written: the runtime
/// on this Mac keeps it, and a server is only ever given the lendable part, in memory.
public struct MacFileSignIn: Sendable {
    public let runtimeID: String
    public let signIn: LentFileSignIn
    public let file: URL

    /// Nil for a runtime without a file sign-in to lend.
    public init?(runtimeID: String, home: String = NSHomeDirectory(),
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let signIn = RuntimeLaunchCatalog.launch(for: runtimeID).lentSignIn else { return nil }
        self.runtimeID = runtimeID
        self.signIn = signIn
        self.file = signIn.file(home: home, environment: environment)
    }

    /// What reading it found.
    public struct Reading: Hashable, Sendable {
        /// The entries a server may borrow, or nil for none.
        public var lendable: LentSignInContent?
        /// The providers in `lendable`, sorted. Names only.
        public var lent: [String] = []
        /// The providers this Mac is signed in to that stay on it, because they rotate.
        public var kept: [String]
        /// The file is there and is not what the runtime writes.
        public var unreadable: Bool

        /// How many providers are lent.
        public var providers: Int { lendable?.providers ?? 0 }
    }

    public func read() -> Reading {
        guard let data = try? Data(contentsOf: file) else { return Reading(lendable: nil, kept: [], unreadable: false) }
        guard let split = signIn.split(data) else { return Reading(lendable: nil, kept: [], unreadable: true) }
        let lendable = split.content.map { LentSignInContent($0, providers: split.lendable.count) }
        return Reading(lendable: lendable, lent: split.lendable.keys.sorted(), kept: split.kept, unreadable: false)
    }
}
