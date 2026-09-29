import Foundation

/// A runtime whose sign-in is one file of providers, which a server run borrows from the Mac
/// in one variable (049 D7: OpenCode's `auth.json`, as `OPENCODE_AUTH_CONTENT`).
///
/// Only entries that never rotate are lent. A browser sign-in (OpenCode's `oauth`) refreshes
/// its token as it is used, and a server refreshing the Mac's would leave the Mac's copy
/// stale, as 047 found for Codex. Those stay on the Mac and are named, never sent.
public struct LentFileSignIn: Hashable, Sendable {
    /// The variable the runtime reads the whole file from instead of the file.
    public var variable: String
    /// Where the file is: `$<dataHomeVariable>/<dataHomePath>`, or else
    /// `$HOME/<defaultPath>`.
    public var dataHomeVariable: String
    public var dataHomePath: String
    public var defaultPath: String
    /// The entry `type`s that are lent.
    public var lendableTypes: Set<String>
    /// How the sheet names the command that adds a provider, on the Mac.
    public var signInCommand: String

    public init(variable: String, dataHomeVariable: String, dataHomePath: String, defaultPath: String,
                lendableTypes: Set<String>, signInCommand: String) {
        self.variable = variable
        self.dataHomeVariable = dataHomeVariable
        self.dataHomePath = dataHomePath
        self.defaultPath = defaultPath
        self.lendableTypes = lendableTypes
        self.signInCommand = signInCommand
    }

    /// The file, for a home and an environment.
    public func file(home: String, environment: [String: String]) -> URL {
        if let data = environment[dataHomeVariable], !data.isEmpty {
            return URL(filePath: data, directoryHint: .isDirectory).appending(path: dataHomePath)
        }
        return URL(filePath: home, directoryHint: .isDirectory).appending(path: defaultPath)
    }

    /// A file, split into what may be lent and the providers kept back.
    public struct Split: Hashable, Sendable {
        /// Provider to its entry, as compact JSON, lendable ones only.
        public var lendable: [String: String]
        /// Providers whose entries rotate, and are never lent, sorted.
        public var kept: [String]

        /// The lendable entries as one compact JSON object, or nil for none.
        public var content: String? {
            lendable.isEmpty ? nil : LentFileSignIn.object(lendable)
        }
    }

    /// Nil when the file is not a JSON object.
    public func split(_ data: Data) -> Split? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var lendable: [String: String] = [:]
        var kept: [String] = []
        for (provider, entry) in object {
            guard let entry = entry as? [String: Any], let type = entry["type"] as? String,
                  lendableTypes.contains(type),
                  let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
                kept.append(provider)
                continue
            }
            lendable[provider] = String(decoding: json, as: UTF8.self)
        }
        return Split(lendable: lendable, kept: kept.sorted())
    }

    /// What a server run is given: the server's own lendable entries with the Mac's over them,
    /// a provider in both taking the Mac's. The variable replaces the file outright (research
    /// R12), so without the server's own a lent run would lose them. The server's rotating
    /// entries are left out, because the runtime writes the whole set back to the file when it
    /// refreshes one, and that would put the Mac's keys on the server's disk.
    public func merged(lent: String, own: Data?) -> String {
        var all = own.flatMap(split)?.lendable ?? [:]
        for (provider, entry) in split(Data(lent.utf8))?.lendable ?? [:] { all[provider] = entry }
        return Self.object(all)
    }

    static func object(_ entries: [String: String]) -> String {
        let all = entries.compactMapValues { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A lent file sign-in's text, which only ever prints as how many providers it holds (049).
///
/// As `Secret`: not `Codable`, and every description is the summary, so a log line or an
/// error that interpolates one cannot write it out. `reveal()` is the one way to the text.
public struct LentSignInContent: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    private let text: String
    public let providers: Int

    public init(_ text: String, providers: Int) {
        self.text = text
        self.providers = providers
    }

    public func reveal() -> String { text }

    public var description: String { providers == 1 ? "sign-in (1 provider)" : "sign-in (\(providers) providers)" }
    public var debugDescription: String { "LentSignInContent(\(description))" }
    public var customMirror: Mirror { Mirror(self, children: ["providers": providers]) }
}
