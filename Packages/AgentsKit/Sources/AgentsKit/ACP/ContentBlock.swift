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
    case resourceLink(uri: String, name: String, mimeType: String?, size: Int?)
    case resource(uri: String, text: String?, blob: Data?, mimeType: String?)
    case unknown(JSONValue)

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
        case .resource(_, let text, _, _): return text
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
                                 size: wire["size"]?.intValue)
        case "resource":
            let resource = wire["resource"] ?? wire
            guard let uri = resource["uri"]?.stringValue else { self = .unknown(wire); return }
            self = .resource(uri: uri,
                             text: resource["text"]?.stringValue,
                             blob: resource["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) },
                             mimeType: resource["mimeType"]?.stringValue)
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
        case .resourceLink(let uri, let name, let mimeType, let size):
            var object: [String: JSONValue] = ["type": "resource_link",
                                               "uri": .string(uri),
                                               "name": .string(name)]
            if let mimeType { object["mimeType"] = .string(mimeType) }
            if let size { object["size"] = .int(size) }
            return .object(object)
        case .resource(let uri, let text, let blob, let mimeType):
            var resource: [String: JSONValue] = ["uri": .string(uri)]
            if let text { resource["text"] = .string(text) }
            if let blob { resource["blob"] = .string(blob.base64EncodedString()) }
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            return ["type": "resource", "resource": .object(resource)]
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
