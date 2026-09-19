import Foundation

/// A piece of a message, in either direction.
///
/// The protocol has always sent messages as a list of these. 001 flattened them to a
/// string, which is why an image in a reply drew as an empty line: the text of an image
/// block is nothing. Keeping the blocks means a picture is a picture going out as well
/// as coming in, and it costs one type.
///
/// A kind we do not know becomes `.unknown` holding what was sent. Nothing is dropped
/// on the way in, and nothing we did not understand is sent back out as something else.
public enum ContentBlock: Codable, Hashable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String, uri: String?)
    case audio(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String, mimeType: String?, size: Int?,
                      annotations: Annotations? = nil)
    case resource(uri: String, text: String?, blob: Data?, mimeType: String?,
                  annotations: Annotations? = nil)
    case unknown(JSONValue)

    /// What an agent says about who a thing is for and how much it matters.
    ///
    /// The protocol allows these on any block and puts them to most use on the two
    /// that hand something over. The artifacts pane reads `audience`: a block marked
    /// for someone other than the user is not the user's artifact.
    public struct Annotations: Codable, Hashable, Sendable {
        public var audience: [String]?
        public var priority: Double?

        public init(audience: [String]? = nil, priority: Double? = nil) {
            self.audience = audience
            self.priority = priority
        }

        /// Whether this is for the person at the screen.
        ///
        /// No annotations at all means yes. An agent that bothered to send a resource
        /// link meant it, and the protocol does not require it to say so twice.
        public var isForUser: Bool {
            guard let audience else { return true }
            return audience.contains("user")
        }

        init?(wire: JSONValue?) {
            guard let wire, wire.objectValue != nil else { return nil }
            let audience = wire["audience"]?.arrayValue?.compactMap(\.stringValue)
            let priority: Double? = switch wire["priority"] {
            case .double(let value): value
            case .int(let value): Double(value)
            default: nil
            }
            guard audience != nil || priority != nil else { return nil }
            self.audience = audience
            self.priority = priority
        }

        var wire: JSONValue {
            var object: [String: JSONValue] = [:]
            if let audience { object["audience"] = .array(audience.map { .string($0) }) }
            if let priority { object["priority"] = .double(priority) }
            return .object(object)
        }
    }

    /// The annotations on this block, when it carries any.
    public var annotations: Annotations? {
        switch self {
        case .resourceLink(_, _, _, _, let annotations): return annotations
        case .resource(_, _, _, _, let annotations): return annotations
        default: return nil
        }
    }

    /// What a runtime has to advertise before we may send this. Nil means baseline:
    /// text and resource links need nothing, which is the protocol's own rule.
    public enum Requirement: String, Hashable, Sendable {
        case image, audio, embeddedContext
    }

    public var requirement: Requirement? {
        switch self {
        case .image: return .image
        case .audio: return .audio
        case .resource: return .embeddedContext
        case .text, .resourceLink, .unknown: return nil
        }
    }

    /// The text in this block, if it has any. An image has none, which is the point.
    public var text: String? {
        switch self {
        case .text(let text): return text
        case .resource(_, let text, _, _, _): return text
        default: return nil
        }
    }

    // MARK: The wire

    public init(wire: JSONValue) {
        switch wire["type"]?.stringValue {
        case "text":
            self = .text(wire["text"]?.stringValue ?? "")
        case "image":
            self = .image(data: Self.data(in: wire),
                          mimeType: wire["mimeType"]?.stringValue ?? "application/octet-stream",
                          uri: wire["uri"]?.stringValue)
        case "audio":
            self = .audio(data: Self.data(in: wire),
                          mimeType: wire["mimeType"]?.stringValue ?? "application/octet-stream")
        case "resource_link":
            guard let uri = wire["uri"]?.stringValue else { self = .unknown(wire); return }
            self = .resourceLink(uri: uri,
                                 name: wire["name"]?.stringValue ?? Self.lastComponent(of: uri),
                                 mimeType: wire["mimeType"]?.stringValue,
                                 size: wire["size"]?.intValue,
                                 annotations: Annotations(wire: wire["annotations"]))
        case "resource":
            let resource = wire["resource"] ?? wire
            guard let uri = resource["uri"]?.stringValue else { self = .unknown(wire); return }
            self = .resource(uri: uri,
                             text: resource["text"]?.stringValue,
                             blob: resource["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) },
                             mimeType: resource["mimeType"]?.stringValue,
                             // On the block, not inside the resource: that is where
                             // the schema puts them.
                             annotations: Annotations(wire: wire["annotations"]))
        default:
            self = .unknown(wire)
        }
    }

    public var wire: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType, let uri):
            var object: [String: JSONValue] = ["type": "image",
                                               "mimeType": .string(mimeType),
                                               "data": .string(data.base64EncodedString())]
            if let uri { object["uri"] = .string(uri) }
            return .object(object)
        case .audio(let data, let mimeType):
            return ["type": "audio", "mimeType": .string(mimeType),
                    "data": .string(data.base64EncodedString())]
        case .resourceLink(let uri, let name, let mimeType, let size, let annotations):
            var object: [String: JSONValue] = ["type": "resource_link",
                                               "uri": .string(uri),
                                               "name": .string(name)]
            if let mimeType { object["mimeType"] = .string(mimeType) }
            if let size { object["size"] = .int(size) }
            if let annotations { object["annotations"] = annotations.wire }
            return .object(object)
        case .resource(let uri, let text, let blob, let mimeType, let annotations):
            var resource: [String: JSONValue] = ["uri": .string(uri)]
            if let text { resource["text"] = .string(text) }
            if let blob { resource["blob"] = .string(blob.base64EncodedString()) }
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            var object: [String: JSONValue] = ["type": "resource", "resource": .object(resource)]
            if let annotations { object["annotations"] = annotations.wire }
            return .object(object)
        case .unknown(let value):
            return value
        }
    }

    // MARK: Stored as sent

    /// Encoded as the protocol's own shape, so the record holds what came over the
    /// wire rather than a translation of it. A block this version cannot read still
    /// round-trips through a newer one.
    public init(from decoder: any Decoder) throws {
        self.init(wire: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try wire.encode(to: encoder)
    }

    private static func data(in wire: JSONValue) -> Data {
        wire["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
    }

    private static func lastComponent(of uri: String) -> String {
        URL(string: uri)?.lastPathComponent ?? uri
    }
}

extension [ContentBlock] {
    /// The text of a message, for the places that read rather than draw: the title of
    /// an agent, a search, a record written by an older version.
    public var plainText: String {
        compactMap(\.text).joined()
    }

    public init(wire: JSONValue?) {
        guard let wire else { self = []; return }
        if let blocks = wire.arrayValue {
            self = blocks.map(ContentBlock.init(wire:))
        } else {
            self = [ContentBlock(wire: wire)]
        }
    }

    public var wire: JSONValue { .array(map(\.wire)) }
}
