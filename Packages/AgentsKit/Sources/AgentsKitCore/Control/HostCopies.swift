import Foundation

/// What each host last answered for its folders and its live sessions (#962), so a client
/// that starts while a host is offline or stopped still lists them, greyed, as one that was
/// running when the host went does.
///
/// Taken from the host's own replies as they pass through the router, never asked for, and
/// only whole lists: `folders/list`, and the first lean page of `agents/list`'s live sessions,
/// at most `agentsKept` of them. Kept in the store, one object a host, so a restart keeps them;
/// a host removed takes its copy with it.
public actor HostCopies {
    /// The most sessions kept for one host: a page's worth, as the clients list them.
    public static let agentsKept = 500
    static let prefix = "v1/copies/"
    static func key(_ host: MachineRef) -> String { prefix + host.rawValue + ".json" }

    struct Copy: Codable, Equatable {
        var folders: JSONValue?
        var agents: JSONValue?
        var heardAt: Date
    }

    private let store: any ControlStore
    private var copies: [MachineRef: Copy] = [:]
    private var read: Set<MachineRef> = []

    public init(store: any ControlStore) { self.store = store }

    /// Whether a request's answer is a whole list worth keeping: every folder, or the first
    /// page of the live sessions, lean, with nothing narrowing it.
    public nonisolated static func keeps(_ method: String, _ params: JSONValue?) -> Bool {
        switch method {
        case DaemonAPI.Method.foldersList:
            return true
        case DaemonAPI.Method.agentsList:
            guard let asked = params?.objectValue else { return false }
            let off: (String) -> Bool = { asked[$0] == nil || asked[$0] == .bool(false) || asked[$0] == .null }
            let absent: (String) -> Bool = { asked[$0] == nil || asked[$0] == .null }
            return asked["lean"] == .bool(true) && off("includeArchived") && off("archivedOnly")
                && ["folder", "startedByWorkflow", "agentID", "after", "query"].allSatisfy(absent)
        default:
            return false
        }
    }

    /// A host's reply to a request `keeps` chose, as it came: a success is kept, anything
    /// else is not.
    public func take(_ host: MachineRef, method: String, reply: String) async {
        guard case .success(_, let result)? = try? JSONRPCCodec.decode(line: reply),
              case .array(let items) = result else { return }
        var copy = await current(host) ?? Copy(heardAt: Date())
        if method == DaemonAPI.Method.foldersList {
            copy.folders = result
        } else {
            copy.agents = .array(Array(items.prefix(Self.agentsKept)))
        }
        copy.heardAt = Date()
        copies[host] = copy
        guard let data = try? ControlRecords.encoder.encode(copy) else { return }
        _ = try? await store.put(Self.key(host), data, when: .always)
    }

    /// What the host last said, for `machines/lastHeard`: its folders and live sessions as it
    /// listed them, and when; nothing when it never has.
    public func lastHeard(_ host: MachineRef) async -> JSONValue {
        guard let copy = await current(host) else { return ["host": .string(host.rawValue)] }
        var said: [String: JSONValue] = ["host": .string(host.rawValue)]
        said["folders"] = copy.folders
        said["agents"] = copy.agents
        said["heardAt"] = try? JSONValue.encoding(copy.heardAt)
        return .object(said)
    }

    /// A host removed: what was kept of it goes.
    public func forget(_ host: MachineRef) async {
        copies[host] = nil
        read.insert(host)
        try? await store.delete(Self.key(host))
    }

    private func current(_ host: MachineRef) async -> Copy? {
        if !read.contains(host) {
            read.insert(host)
            if copies[host] == nil, let object = try? await store.get(Self.key(host)),
               let stored = try? ControlRecords.decoder.decode(Copy.self, from: object.data) {
                copies[host] = stored
            }
        }
        return copies[host]
    }
}

public extension DaemonAPI {
    /// `machines/lastHeard`'s answer (#962): what a host last listed, for a client that starts
    /// while it is offline. Each is missing when the host has never listed it here.
    struct MachineLastHeard: Codable, Sendable {
        public var host: MachineRef
        public var folders: [FolderSummary]?
        public var agents: [Agent]?
        public var heardAt: Date?
    }
}

public extension DaemonAPI.Method {
    /// `MachineRequest` → `MachineLastHeard`.
    static let hostsLastHeard = "machines/lastHeard"
}
