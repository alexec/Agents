import Foundation
import Testing
@testable import AgentsKitCore

/// Today's Swift encoders against Packages/Wire, the schema every other language is made from
/// (#1135). The Swift `Model` types stay written by hand; this is what keeps them and the
/// schema the same. A change to a type on the wire changes `daemon.schema.json` first, then
/// `scripts/wire.sh gen` makes the Go and the TypeScript, and this test says what to change in
/// Swift by hand.
@Suite("Wire schema")
struct WireSchemaTests {
    static let wire = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Wire")
    static let fixtures = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/web")

    static func read(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: wire.appending(path: name)))
    }

    /// The records in the web fixtures, told apart by their keys, and the Swift type each is.
    struct Kind: Sendable {
        var name: String
        var matches: @Sendable ([String: JSONValue]) -> Bool
        /// Read with today's decoder and written again with today's encoder, so what is
        /// checked is the product's own output, not the fixture's.
        var encode: @Sendable (JSONValue) throws -> JSONValue
    }

    static func through<T: Codable>(_: T.Type) -> @Sendable (JSONValue) throws -> JSONValue {
        { try JSONValue.encoding(try JSONDecoder().decode(T.self, from: JSONEncoder().encode($0))) }
    }

    static func has(_ object: [String: JSONValue], _ keys: String...) -> Bool {
        keys.allSatisfy { object[$0] != nil }
    }

    static let kinds: [Kind] = [
        Kind(name: "Agent", matches: { has($0, "id", "runtimeID", "cwd", "state", "createdAt") }, encode: through(Agent.self)),
        Kind(name: "TranscriptEntry", matches: { has($0, "id", "at", "kind") && $0.count <= 5 },
             encode: through(TranscriptEntry.self)),
        Kind(name: "RuntimeStatus", matches: { has($0, "runtime", "availability") }, encode: through(RuntimeStatus.self)),
        Kind(name: "PermissionRequest", matches: { has($0, "id", "agentID", "toolCall", "options", "askedAt") },
             encode: through(PermissionRequest.self)),
        Kind(name: "WorkflowSummary", matches: { has($0, "workflow", "isEnabled", "isRunning") },
             encode: through(WorkflowSummary.self)),
    ]

    /// The types whose encoders are written by hand, by the fixture of samples of each.
    static let samples: [String: @Sendable (JSONValue) throws -> JSONValue] = [
        "ConfigOption": through(ConfigOption.self),
        "ContentBlock": through(ContentBlock.self),
        "FileReading": through(FileReading.self),
        "GitView": through(GitView.self),
        "NeedID": through(NeedID.self),
        "RuntimeAvailability": through(RuntimeAvailability.self),
        "Surface": through(Surface.self),
        "ToolCallContent": through(ToolCallContent.self),
        "WorkflowTrigger": through(WorkflowTrigger.self),
    ]

    static func walk(_ value: JSONValue, _ found: ([String: JSONValue]) -> Void) {
        switch value {
        case .object(let object):
            found(object)
            object.values.forEach { walk($0, found) }
        case .array(let array):
            array.forEach { walk($0, found) }
        default:
            break
        }
    }

    @Test func todaysEncodersWriteWhatTheSchemaSays() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        var found: [String: Int] = [:]
        var failures: [String] = []
        let files = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(!files.isEmpty, "no fixtures at \(Self.fixtures.path)")
        for file in files {
            let value = try JSONValue.parse(Data(contentsOf: file))
            if file.deletingLastPathComponent().lastPathComponent == "overrides" {
                let name = file.deletingPathExtension().lastPathComponent
                guard let encode = Self.samples[name] else {
                    Issue.record("overrides/\(name).json: no Swift type is checked against it")
                    continue
                }
                for sample in value.arrayValue ?? [] {
                    guard let input = sample["input"] else { continue }
                    failures += schema.errors(try encode(input), against: name).map { "\(name) in \(file.lastPathComponent): \($0)" }
                    found[name, default: 0] += 1
                }
                continue
            }
            Self.walk(value) { object in
                guard let kind = Self.kinds.first(where: { $0.matches(object) }) else { return }
                // A fixture the product does not read (the input of a test of a refusal,
                // say) says nothing about what it writes.
                guard let written = try? kind.encode(.object(object)) else { return }
                found[kind.name, default: 0] += 1
                failures += schema.errors(written, against: kind.name).map { "\(kind.name) in \(file.lastPathComponent): \($0)" }
            }
        }
        for name in Self.kinds.map(\.name) + Self.samples.keys.sorted() {
            #expect(found[name, default: 0] > 0, "no \(name) in the fixtures")
        }
        #expect(failures.isEmpty, "\(failures.count) records do not fit the schema:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// The checker itself finds what is wrong, so a pass above means something.
    @Test func theCheckerRefusesWhatTheSchemaDoesNot() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        let entry: [String: JSONValue] = [
            "id": "00000000-0000-0000-0000-000000000001", "at": 812_500_000,
            "kind": ["agentMessage": ["text": "hello"]],
        ]
        #expect(schema.errors(.object(entry), against: "TranscriptEntry") == [])
        var wrong = entry
        wrong["at"] = "yesterday"
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        wrong = entry
        wrong["colour"] = "blue"
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        wrong = entry
        wrong["id"] = nil
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        // A kind this build does not know is kept whole, so any one-key object is a kind.
        #expect(schema.errors(["teleported": ["to": "Mars"]], against: "TranscriptEntryKind") == [])
        #expect(!schema.errors(["agentMessage": ["words": "hello"]], against: "TranscriptEntryKind").isEmpty)
        #expect(!schema.errors("hibernating", against: "EndedReason").isEmpty)
        #expect(!schema.errors(1.5, against: "TranscriptPage", at: "firstIndex").isEmpty)
    }

    /// WebSignatures, which the web page's tests and the grants read, and the OpenRPC documents
    /// the TypeScript is made from, name the same methods going to the same place.
    @Test func webSignaturesAreTheMethodsTaggedWeb() throws {
        var documented: [String: DaemonAPI.WebSignatures.Kind] = [:]
        for (file, request, notification) in [
            ("daemon.openrpc.json", DaemonAPI.WebSignatures.Kind.hostRequest, DaemonAPI.WebSignatures.Kind.hostNotification),
            ("control.openrpc.json", .controlRequest, .controlNotification),
        ] {
            for method in try Self.read(file)["methods"]?.arrayValue ?? [] {
                let tags = method["tags"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
                guard tags.contains("web"), let name = method["name"]?.stringValue else { continue }
                documented[name] = method["x-notification"]?.boolValue == true ? notification : request
            }
        }
        let rows = Dictionary(uniqueKeysWithValues: DaemonAPI.WebSignatures.rows.map { ($0.method, $0.kind) })
        #expect(Set(rows.keys).subtracting(documented.keys).sorted() == [], "in WebSignatures, not in Packages/Wire")
        #expect(Set(documented.keys).subtracting(rows.keys).sorted() == [], "in Packages/Wire, not in WebSignatures")
        for (method, kind) in rows where documented[method] != nil {
            #expect(documented[method] == kind, "\(method) goes to a different place")
        }
    }
}

/// The part of JSON Schema draft-07 that daemon.schema.json uses, checked against a value.
struct WireSchema {
    let definitions: [String: JSONValue]

    init(_ document: JSONValue) throws {
        definitions = document["definitions"]?.objectValue ?? [:]
    }

    /// What is wrong with `value` as the definition `name` (or one of its properties).
    func errors(_ value: JSONValue, against name: String, at property: String? = nil) -> [String] {
        guard var schema = definitions[name] else { return ["no definition \(name)"] }
        if let property {
            guard let inner = schema["properties"]?[property] else { return ["\(name) has no \(property)"] }
            schema = inner
        }
        return errors(value, schema, name)
    }

    private func errors(_ value: JSONValue, _ schema: JSONValue, _ path: String) -> [String] {
        if let ref = schema["$ref"]?.stringValue {
            let name = String(ref.split(separator: "/").last ?? "")
            guard let target = definitions[name] else { return ["\(path): $ref \(ref) names nothing"] }
            return errors(value, target, path)
        }
        // A case this build does not know is kept whole and written back (x-fallback: keep);
        // a case it knows is checked as that case.
        if schema["x-fallback"]?.stringValue == "keep", let object = value.objectValue, object.count == 1,
           let cases = schema["anyOf"]?.arrayValue?.compactMap({ $0["properties"]?.objectValue?.keys.first }),
           !cases.contains(object.keys.first ?? "") {
            return []
        }
        if let options = schema["anyOf"]?.arrayValue {
            let each = options.map { errors(value, $0, path) }
            return each.contains { $0.isEmpty } ? [] : ["\(path): fits none of \(options.count) shapes (\(each.map { $0.first ?? "" }.joined(separator: "; ")))"]
        }
        if let constant = schema["const"], constant != value { return ["\(path): \(value) is not \(constant)"] }
        if let values = schema["enum"]?.arrayValue, !values.contains(value) { return ["\(path): \(value) is not one of its values"] }
        if let types = schema["type"].map({ $0.arrayValue ?? [$0] })?.compactMap(\.stringValue),
           !types.contains(where: { fits(value, $0) }) {
            return ["\(path): \(value) is not \(types.joined(separator: " or "))"]
        }
        var found: [String] = []
        switch value {
        case .object(let object):
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[required] == nil {
                found.append("\(path): \(required) is missing")
            }
            for (key, inner) in object {
                if let property = properties[key] {
                    found += errors(inner, property, "\(path).\(key)")
                } else if let more = schema["additionalProperties"] {
                    if more == .bool(false) {
                        found.append("\(path): \(key) is not in the schema")
                    } else if more["not"] != nil {
                        found.append("\(path): \(key) is not allowed")
                    } else if more != .bool(true) {
                        found += errors(inner, more, "\(path).\(key)")
                    }
                }
            }
        case .array(let array):
            if let least = schema["minItems"]?.intValue, array.count < least { found.append("\(path): fewer than \(least) items") }
            if let most = schema["maxItems"]?.intValue, array.count > most { found.append("\(path): more than \(most) items") }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() {
                    found += errors(item, items, "\(path)[\(index)]")
                }
            }
        default:
            break
        }
        return found
    }

    private func fits(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
             ("number", .int), ("number", .double), ("integer", .int):
            return true
        case ("integer", .double(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }
}
