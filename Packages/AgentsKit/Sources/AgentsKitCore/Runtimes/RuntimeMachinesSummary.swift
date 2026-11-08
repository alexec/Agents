import Foundation

/// A runtime's machines on Status ▸ Runtimes, in one line (#3744): "On all 3 machines", or
/// "On This Mac · Not on build-box". It takes the place of a line per machine; each name in
/// it is a link to that machine's page, which has the whole line (`machineLine`). The web
/// page's `machinesSummary` says the same.
public struct RuntimeMachinesSummary<Machine: Hashable> {
    /// The words before some machines' names, such as "Not on", and those machines. "On all 3
    /// machines" names none.
    public struct Part: Equatable {
        public var words: String
        public var machines: [Machine]
    }

    public let parts: [Part]
    /// Installed, or being installed, on at least one machine: the runtime is in use, and is
    /// not one of the other runtimes.
    public let inUse: Bool

    /// Each machine in its order, with the runtime's status there (nil when the machine has not
    /// listed it) and whether the machine is online.
    public init(_ machines: [(machine: Machine, status: RuntimeStatus?, online: Bool)]) {
        let groups = Self.order.map { kind in machines.filter { Self.kind($0.status, online: $0.online) == kind }.map(\.machine) }
        let outdated = machines.filter { $0.status?.outdated == true }.map(\.machine)
        inUse = machines.contains { if let status = $0.status { !status.availability.isMissing } else { false } }
        var parts: [Part] = []
        if machines.count > 1, groups[0].count == machines.count {
            parts.append(Part(words: "On all \(machines.count) machines", machines: []))
        } else {
            for (kind, group) in zip(Self.order, groups) where !group.isEmpty {
                parts.append(Part(words: kind.words, machines: group))
            }
        }
        if !outdated.isEmpty { parts.append(Part(words: "An update is out on", machines: outdated)) }
        self.parts = parts
    }

    /// The line as plain words, for a test or a screen reader: "On This Mac, devbox · Not on build-box".
    public func words(_ name: (Machine) -> String) -> String {
        parts.map { part in
            ([part.words] + [part.machines.map(name).joined(separator: ", ")].filter { !$0.isEmpty }).joined(separator: " ")
        }.joined(separator: " · ")
    }

    private enum Kind: Equatable {
        case ready, notSignedIn, cannotUse, installing, notInstalled, offline, notKnown

        var words: String {
            switch self {
            case .ready: "On"
            case .notSignedIn: "Not signed in on"
            case .cannotUse: "Can’t be used on"
            case .installing: "Installing on"
            case .notInstalled: "Not on"
            case .offline: "Offline:"
            case .notKnown: "Not known yet on"
            }
        }
    }

    private static var order: [Kind] { [.ready, .notSignedIn, .cannotUse, .installing, .notInstalled, .offline, .notKnown] }

    private static func kind(_ status: RuntimeStatus?, online: Bool) -> Kind {
        guard let status else { return online ? .notKnown : .offline }
        switch status.availability {
        case .available:
            if let signIn = status.signIn, !signIn.signedIn, signIn.relayed != true { return .notSignedIn }
            return .ready
        case .needsSignIn: return .notSignedIn
        case .missing: return .notInstalled
        case .failed, .installFailed: return .cannotUse
        case .installing: return .installing
        }
    }
}
