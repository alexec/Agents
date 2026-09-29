import Foundation

/// The link between two copies of the control plane (058, US3; contracts/wire.md "Copy ⇄
/// copy"). A stream for a host is the host wire with `"p":"<host>"` in front; the rest are
/// small objects of their own.
public enum PeerWire {
    public enum Frame: Sendable {
        /// A host frame, for a stream one copy carries to a host the other holds.
        case stream(HostID, ControlWire.HostFrame)
        /// The sender no longer holds the host.
        case gone(HostID, epoch: Int)
        /// The sender holds the host now (or no longer, when offline).
        case host(HostID, online: Bool, epoch: Int)
        /// A change a person made, applied at every copy.
        case event(ControlEvent)
        /// A client here said where the person is.
        case presence(client: UUID, grant: Grant, report: DaemonAPI.PresenceReport)
        /// A host's `attention/need`, for the copy that holds a relay host (T097).
        case need(DaemonAPI.AttentionNeed)
    }

    /// `{"p":"H","c":…}` from a host frame's line.
    public static func frame(_ host: HostID, _ hostLine: String) -> String {
        #"{"p":""# + host.rawValue + #"","# + hostLine.dropFirst()
    }

    public static func gone(_ host: HostID, epoch: Int) -> String {
        #"{"p":""# + host.rawValue + #"","gone":{"epoch":"# + String(epoch) + "}}"
    }

    public static func host(_ host: HostID, online: Bool, epoch: Int) -> String {
        encode(["host": .object(["id": .string(host.rawValue), "state": .string(online ? "online" : "offline"),
                                 "epoch": .int(epoch)])])
    }

    public static func event(_ event: ControlEvent) -> String {
        encode(["event": (try? JSONValue.encoding(event)) ?? .null])
    }

    public static func presence(client: UUID, grant: Grant, report: DaemonAPI.PresenceReport) -> String {
        encode(["presence": .object(["client": .string(client.uuidString), "grant": .string(grant.rawValue),
                                     "report": (try? JSONValue.encoding(report)) ?? .null])])
    }

    public static func need(_ need: DaemonAPI.AttentionNeed) -> String {
        encode(["need": (try? JSONValue.encoding(need)) ?? .null])
    }

    public static func read(_ line: String) -> Frame? {
        if line.hasPrefix(#"{"p":""#) {
            let rest = line.dropFirst(6)
            guard let quote = rest.firstIndex(of: "\"") else { return nil }
            let host = HostID(rawValue: String(rest[..<quote]))
            let after = rest[rest.index(after: quote)...]
            guard after.hasPrefix(",") else { return nil }
            let hostLine = "{" + after.dropFirst()
            if hostLine.hasPrefix(#"{"gone":"#) {
                let epoch = (try? JSONValue.parse(Data(hostLine.utf8)))?["gone"]?["epoch"]?.intValue ?? 0
                return .gone(host, epoch: epoch)
            }
            return (try? ControlWire.readHost(hostLine)).map { .stream(host, $0) }
        }
        guard let object = try? JSONValue.parse(Data(line.utf8)).objectValue else { return nil }
        if let host = object["host"], let id = host["id"]?.stringValue {
            return .host(HostID(rawValue: id), online: host["state"]?.stringValue == "online",
                         epoch: host["epoch"]?.intValue ?? 0)
        }
        if let event = object["event"], let decoded = try? event.decode(ControlEvent.self) {
            return .event(decoded)
        }
        if let presence = object["presence"], let client = presence["client"]?.stringValue.flatMap(UUID.init(uuidString:)),
           let grant = presence["grant"]?.stringValue.flatMap(Grant.init(rawValue:)),
           let report = try? presence["report"]?.decode(DaemonAPI.PresenceReport.self) {
            return .presence(client: client, grant: grant, report: report)
        }
        if let need = object["need"], let decoded = try? need.decode(DaemonAPI.AttentionNeed.self) {
            return .need(decoded)
        }
        return nil
    }

    private static func encode(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(JSONValue.object(object))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
