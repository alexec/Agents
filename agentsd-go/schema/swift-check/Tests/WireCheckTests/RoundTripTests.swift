import AgentsKitCore
import Foundation
import Testing
import WireTypes

/// Each Swift-encoded fixture record is decoded into today's AgentsKitCore type and encoded
/// again with today's encoder (JSONValue.encoding: a plain JSONEncoder), so what is checked
/// is the product's own output, not the fixture's. That JSON must decode into the type
/// generated from the schema, and encode back to the same JSON.
struct RoundTripTests {
    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../internal/wire/testdata/web").standardized

    struct Kind {
        let name: String
        let matches: ([String: Any]) -> Bool
        let product: (Data) throws -> Data
        let generated: (Data) throws -> Data
    }

    static func through<P: Codable, G: Codable>(_: P.Type, _: G.Type) -> ((Data) throws -> Data, (Data) throws -> Data) {
        ({ try JSONEncoder().encode(try JSONDecoder().decode(P.self, from: $0)) },
         { try JSONEncoder().encode(try JSONDecoder().decode(G.self, from: $0)) })
    }

    static func has(_ m: [String: Any], _ keys: String...) -> Bool { keys.allSatisfy { m[$0] != nil } }

    static let kinds: [Kind] = {
        let agent = through(Agent.self, WAgent.self)
        let entry = through(TranscriptEntry.self, WTranscriptEntry.self)
        let runtime = through(RuntimeStatus.self, WRuntimeStatus.self)
        let permission = through(PermissionRequest.self, WPermissionRequest.self)
        return [
            Kind(name: "Agent", matches: { has($0, "id", "runtimeID", "cwd", "state", "createdAt") }, product: agent.0, generated: agent.1),
            Kind(name: "TranscriptEntry", matches: { has($0, "id", "at", "kind") && $0.count <= 5 }, product: entry.0, generated: entry.1),
            Kind(name: "RuntimeStatus", matches: { has($0, "runtime", "availability") }, product: runtime.0, generated: runtime.1),
            Kind(name: "PermissionRequest", matches: { has($0, "id", "agentID", "toolCall", "options", "askedAt") },
                 product: permission.0, generated: permission.1),
        ]
    }()

    static func walk(_ value: Any, _ found: ([String: Any]) -> Void) {
        if let object = value as? [String: Any] {
            found(object)
            object.values.forEach { walk($0, found) }
        } else if let array = value as? [Any] {
            array.forEach { walk($0, found) }
        }
    }

    static func same(_ a: Data, _ b: Data) -> Bool {
        let x = try? JSONSerialization.jsonObject(with: a), y = try? JSONSerialization.jsonObject(with: b)
        return (x as? NSObject)?.isEqual(y) ?? false
    }

    @Test func productOutputRoundTripsThroughGeneratedTypes() throws {
        var found: [String: Int] = [:], passed: [String: Int] = [:], skipped = 0
        var failures: [String] = []
        let files = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(!files.isEmpty, "no fixtures at \(Self.fixtures.path)")
        for file in files {
            guard let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) else { continue }
            Self.walk(value) { object in
                guard let kind = Self.kinds.first(where: { $0.matches(object) }),
                      let raw = try? JSONSerialization.data(withJSONObject: object) else { return }
                // A fixture the product itself does not read (an input for a test of a
                // refusal, say) says nothing about the schema.
                guard let product = try? kind.product(raw) else { skipped += 1; return }
                found[kind.name, default: 0] += 1
                do {
                    let back = try kind.generated(product)
                    if Self.same(product, back) { passed[kind.name, default: 0] += 1 } else if failures.count < 10 {
                        failures.append("\(kind.name) in \(file.lastPathComponent): \(String(decoding: product, as: UTF8.self).prefix(300)) → \(String(decoding: back, as: UTF8.self).prefix(300))")
                    }
                } catch {
                    if failures.count < 10 { failures.append("\(kind.name) in \(file.lastPathComponent): \(error)") }
                }
            }
        }
        for kind in Self.kinds {
            print("\(kind.name): \(found[kind.name, default: 0]) found, \(passed[kind.name, default: 0]) round-trip")
        }
        print("skipped (the product does not read them): \(skipped)")
        failures.forEach { print($0) }
        for kind in Self.kinds { #expect(found[kind.name, default: 0] == passed[kind.name, default: 0], "\(kind.name)") }
    }
}
