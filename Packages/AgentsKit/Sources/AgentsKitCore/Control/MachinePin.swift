import CryptoKit
import Foundation

/// A Mac pinned to one control plane by its organisation (#998, spec 998 slice 4, US7).
/// IT pushes a configuration profile that sets, in both apps' own domains
/// (`com.alexecollins.agents.host` for Agents Host, `com.alexecollins.agents.store` for the
/// window), three keys and no more: the control plane's address, its key, and must join.
/// Rules always come from the control plane (FR-029): any other key the profile forces is
/// ignored, and said once. Only forced values count, so a person's own `defaults write`
/// pins nothing. Both apps read; neither writes (hosts never escalate).
///
/// `agentsd` checks the same, as `pin.go` (`--pin-address`, `--pin-key`, `--must-join`,
/// or `/etc/agents/policy.json` on Linux).
public struct MachinePin: Sendable, Hashable {
    public static let addressKey = "ControlPlaneAddress"
    public static let keyKey = "ControlPlaneKey"
    public static let mustJoinKey = "MustJoin"

    /// The control plane's host name ("control.acme.dev"), or a URL of it.
    public var address: String?
    /// The control plane's key as a code carries it (base64url), or its key id.
    public var key: String?
    public var mustJoin: Bool

    public init(address: String?, key: String?, mustJoin: Bool) {
        self.address = address.flatMap { $0.isEmpty ? nil : $0 }
        self.key = key.flatMap { $0.isEmpty ? nil : $0 }
        self.mustJoin = mustJoin
    }

    /// The pin a profile forces on these defaults, or nil.
    public static func managed(_ defaults: UserDefaults = .standard, ignored: ([String]) -> Void = { _ in }) -> MachinePin? {
        let forced = defaults.dictionaryRepresentation().filter { defaults.objectIsForced(forKey: $0.key) }
        return read(forced: forced, ignored: ignored)
    }

    /// The pin in the values a profile forces, or nil when they pin nothing. `ignored` is
    /// told the other keys the profile forces in this domain, which are let go.
    public static func read(forced: [String: Any], ignored: ([String]) -> Void = { _ in }) -> MachinePin? {
        let mine = [addressKey, keyKey, mustJoinKey]
        let others = forced.keys.filter { !mine.contains($0) && !Self.system($0) }.sorted()
        if !others.isEmpty { ignored(others) }
        let pin = MachinePin(address: forced[addressKey] as? String, key: forced[keyKey] as? String,
                             mustJoin: (forced[mustJoinKey] as? Bool) ?? false)
        return pin.address == nil && pin.key == nil && !pin.mustJoin ? nil : pin
    }

    /// A key macOS forces for its own reasons, in every domain of a managed Mac.
    private static func system(_ key: String) -> Bool {
        key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") || key.hasPrefix("PayloadUUID")
    }

    /// The pin names a control plane, by its address or its key: no other may be joined.
    public var namesAControlPlane: Bool { address != nil || key != nil }

    /// The address as a host name, lower case, with no port.
    public var host: String? { address.map(Self.host(of:)) }

    static func host(of address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.contains("://") {
            a = URL(string: a)?.host ?? a
        } else if let i = a.firstIndex(where: { $0 == ":" || $0 == "/" }) {
            a = String(a[..<i])
        }
        if a.hasSuffix(".") { a.removeLast() }
        return a.lowercased()
    }

    /// The key id `agentsd` and the policy's signature name a control key by: the first 8
    /// bytes of the SHA-256 of its X9.63 key, base64url.
    public static func keyID(_ controlKey: Data) -> String {
        ControlCode.base64url(Data(SHA256.hash(data: controlKey).prefix(8)))
    }

    /// Whether the control plane with this key, at these addresses, may be paired with,
    /// joined or kept (FR-027).
    public func admits(controlKey: Data, addresses: [String]) -> Bool {
        if let host, !addresses.contains(where: { !$0.isEmpty && Self.host(of: $0) == host }) { return false }
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
           key != ControlCode.base64url(controlKey), key != Self.keyID(controlKey) { return false }
        return true
    }

    /// Whether a control plane at this address may be asked, before its key is known: a
    /// sign-in to pair, whose membership is checked again with `admits(_:)`.
    public func admits(address: String) -> Bool {
        host.map { Self.host(of: address) == $0 } ?? true
    }

    public func admits(_ code: ControlCode) -> Bool {
        admits(controlKey: code.controlKey, addresses: code.addresses + [code.url].compactMap { $0 })
    }

    public func admits(_ membership: ControlMembership) -> Bool {
        admits(controlKey: membership.controlKey,
               addresses: membership.addresses + [membership.url].compactMap { $0 } + (membership.endpoints ?? []).map(\.url))
    }

    /// The control plane the organisation requires, for the words.
    private var required: String { host ?? "its control plane" }

    /// A code, a join or a Forget refused for the pin.
    public var refusal: String { "\(OrgPolicyWords.setBy). This Mac may join \(required) only." }

    /// Forget or leave refused: the Mac stays with the control plane its organisation pins.
    public var leaveRefusal: String { "\(OrgPolicyWords.setBy). This Mac stays joined to \(required)." }

    /// What a Mac that must join, and has not, shows.
    public var mustJoinWords: String { "Your organisation requires this Mac to join \(required)." }

    /// A pairing refused for the pin, with its words.
    public struct Refused: LocalizedError, Sendable {
        public let words: String
        public init(words: String) { self.words = words }
        public var errorDescription: String? { words }
    }

    /// The arguments Agents Host gives `agentsd` (`pin.go`).
    public var arguments: [String] {
        var out: [String] = []
        if let address { out += ["--pin-address", address] }
        if let key { out += ["--pin-key", key] }
        if mustJoin { out.append("--must-join") }
        return out
    }
}
