import Foundation
import Testing
@testable import WebTypesKit

/// Each mapping rule and each refusal in contracts/generated-types.md, on sources of the
/// test's own (071, T019).
@Suite("Web types emitter")
struct EmitterTests {
    static let api = """
    public enum DaemonAPI {
        public enum Method {
            public static let one = "test/one"
            public static let two = "test/two"
        }
        public enum Notification {
            public static let heard = "test/heard"
        }
        public enum Failure {
            public static let broken = -32001
            public static let gone = -32090
        }
    }
    """

    /// The generated file for `types`, with `test/one` taking `params` and returning `result`.
    func generate(_ types: String, params: String = "P", result: String = "R",
                  overrides: [String: String] = [:], extraRows: String = "") throws -> String {
        let table = """
        extension DaemonAPI {
            public enum WebSignatures {
                public static var rows: [Row] {
                    [
                        Row(Method.one, params: \(params).self, result: \(result).self, kind: .hostRequest),
                        \(extraRows)
                    ]
                }
            }
        }
        """
        return try Generator.generate(sources: ["API.swift": Self.api, "Types.swift": types, "Web.swift": table],
                                      signatures: "Web.swift", overrides: overrides)
    }

    func failure(_ body: () throws -> String) -> String {
        do {
            _ = try body()
            return ""
        } catch {
            return String(describing: error)
        }
    }

    // MARK: Mapping

    @Test func structsMapFieldByField() throws {
        let out = try generate("""
        struct P: Codable { var a: String; var b: Int?; var c: [Double]; var d: [String: Bool]; var e: Set<UUID> }
        struct R: Codable { var when: Date; var bytes: Data; var link: URL; var any: JSONValue; var range: ClosedRange<Int>
            var computed: Int { 1 }
            static let shared = 2
            let fixed = 3
        }
        enum JSONValue: Codable { case null; func encode(to encoder: any Encoder) throws {} }
        """)
        #expect(out.contains("export interface P {\n  a: string;\n  b?: number;\n  c: number[];\n  d: Record<string, boolean>;\n  e: UUID[];\n}"))
        #expect(out.contains("export interface R {\n  when: WireDate;\n  bytes: Base64;\n  link: URLString;\n  any: JSONValue;\n  range: [number, number];\n}"))
        #expect(out.contains("\"test/one\": { params: P; result: R };"))
        #expect(out.contains("P: { required: [\"a\", \"c\", \"d\", \"e\"], optional: [\"b\"] },"))
    }

    @Test func codingKeysRenameAndChooseTheKeys() throws {
        let out = try generate("""
        struct P: Codable { var a: String; var skipped: Int = 0
            enum CodingKeys: String, CodingKey { case a = "alpha" }
        }
        struct R: Codable {}
        """)
        #expect(out.contains("export interface P {\n  alpha: string;\n}"))
    }

    @Test func rawRepresentableStructsAreBrandedValues() throws {
        let out = try generate("struct P: RawRepresentable, Codable { var rawValue: String }\nstruct R: Codable {}")
        #expect(out.contains("export type P = string & { readonly __brand: \"P\" };"))
    }

    @Test func enumsWithRawValuesAreUnions() throws {
        let out = try generate("""
        enum P: String, Codable { case a, b = "bee", `default` }
        enum R: Int, Codable { case zero, five = 5, six }
        """)
        #expect(out.contains("export type P = \"a\" | \"bee\" | \"default\";"))
        #expect(out.contains("export type R = 0 | 5 | 6;"))
    }

    @Test func enumsWithPayloadsAreSwiftsSynthesizedShape() throws {
        let out = try generate("""
        enum P: Codable { case plain; case labelled(id: String, note: String?); case bare(Int, Bool) }
        struct R: Codable {}
        """)
        #expect(out.contains("| { plain: Record<string, never> }"))
        #expect(out.contains("| { labelled: { id: string; note?: string } }"))
        #expect(out.contains("| { bare: { _0: number; _1: boolean } }"))
    }

    @Test func nestedTypesResolveFromTheirScopeAndDropDaemonAPI() throws {
        let out = try generate("""
        extension DaemonAPI { struct P: Codable { var kind: Kind; enum Kind: String, Codable { case x } } }
        struct R: Codable { var p: DaemonAPI.P }
        """, params: "DaemonAPI.P")
        #expect(out.contains("export interface P {\n  kind: PKind;\n}"))
        #expect(out.contains("export type PKind = \"x\";"))
    }

    @Test func aliasesAreFollowed() throws {
        let out = try generate("typealias P = [String: Int]\nstruct R: Codable {}")
        #expect(out.contains("\"test/one\": { params: Record<string, number>; result: R };"))
    }

    @Test func aCodingKeyRepresentableKeyIsAnObject() throws {
        let out = try generate("""
        enum K: String, Codable { case a }
        extension K: CodingKeyRepresentable {}
        struct P: Codable { var counts: [K: Int] }
        struct R: Codable {}
        """)
        #expect(out.contains("counts: Partial<Record<K, number>>;"))
    }

    @Test func aPlainKeyedEncoderIsReadFromItsBody() throws {
        let out = try generate("""
        struct P: Codable {
            var id: String
            var tags: [String]
            var note: String?
            var state: String
            var raw: String?
            enum CodingKeys: String, CodingKey { case id, tags = "labels", note, state }
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
                try c.encodeIfPresent(note, forKey: .note)
                try c.encode(raw ?? state, forKey: .state)
            }
        }
        struct R: Codable {}
        """)
        #expect(out.contains("export interface P {\n  id: string;\n  labels?: string[];\n  note?: string;\n  state: string;\n}"))
    }

    @Test func dates2001AndFailuresAreInTheHeader() throws {
        let out = try generate("struct P: Codable {}\nstruct R: Codable {}")
        #expect(out.contains("export const Failure = {\n  broken: -32001,\n  gone: -32090,\n} as const;"))
        #expect(out.contains("Seconds since 2001-01-01T00:00:00Z"))
        #expect(out.contains("\"test/one\": \"host\","))
    }

    @Test func notificationsAreListedApart() throws {
        let out = try generate("struct P: Codable {}\nstruct R: Codable {}\nstruct H: Codable { var x: Int }",
                               extraRows: "Row(Notification.heard, params: H.self, result: R.self, kind: .hostNotification),")
        #expect(out.contains("export interface Notifications {\n  \"test/heard\": H;\n}"))
        #expect(!out.contains("\"test/heard\": { params"))
    }

    @Test func theSameSourceGivesTheSameBytes() throws {
        let types = "struct P: Codable { var b: Int; var a: Int }\nstruct R: Codable { var z: P }"
        #expect(try generate(types) == generate(types))
    }

    // MARK: Overrides

    @Test func anOverrideStandsInForAnEncoderThatCantBeRead() throws {
        let types = """
        enum P: Codable { case a; func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode("a") } }
        struct R: Codable {}
        """
        #expect(failure { try generate(types) }.contains("add Overrides/P.ts"))
        let out = try generate(types, overrides: ["P": "export type P = \"a\";"])
        #expect(out.contains("export type P = \"a\";"))
    }

    @Test func overridesThatArentNeededFail() {
        #expect(failure { try generate("struct P: Codable {}\nstruct R: Codable {}", overrides: ["P": "export type P = {};"]) }
            .contains("Overrides/P.ts is not needed"))
        #expect(failure { try generate("struct P: Codable {}\nstruct R: Codable {}", overrides: ["Nothing": "x"]) }
            .contains("Overrides/Nothing.ts is not needed"))
        let readable = """
        struct P: Codable { var a: Int
            enum CodingKeys: String, CodingKey { case a }
            func encode(to encoder: any Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(a, forKey: .a) }
        }
        struct R: Codable {}
        """
        #expect(failure { try generate(readable, overrides: ["P": "export type P = {};"]) }.contains("the generator reads"))
    }

    @Test func overrideDirectives() throws {
        let types = """
        enum P: Codable { case a(Int); case raw(String)
            func encode(to encoder: any Encoder) throws {}
            private enum Stored: Codable { case b }
        }
        enum R: Codable { case b(Q); func encode(to encoder: any Encoder) throws {} }
        struct Q: Codable { var q: Int }
        """
        let synthesized = try generate(types, overrides: ["P": "// as synthesized\n// passthrough: raw", "R": "// uses: Q\nexport type R = Q;"])
        #expect(synthesized.contains("export type P =\n  | { a: { _0: number } };"))
        #expect(synthesized.contains("export interface Q {"))
        let aliased = try generate(types, overrides: ["P": "// as: Stored", "R": "// uses: Q\nexport type R = Q;"])
        #expect(aliased.contains("export type P = PStored;"))
    }

    // MARK: Refusals

    @Test func whatHasNoTypeScriptFormIsRefusedByName() {
        #expect(failure { try generate("struct P: Codable { var x: Missing }\nstruct R: Codable {}") }
            .contains("Missing is used by P.x but not declared"))
        #expect(failure { try generate("struct P: Codable { var m: [UUID: Int] }\nstruct R: Codable {}") }
            .contains("array of keys and values"))
        #expect(failure { try generate("struct P<T>: Codable { var t: Int }\nstruct R: Codable {}") }.contains("generic"))
        #expect(failure { try generate("final class P: Codable {}\nstruct R: Codable {}") }.contains("is a class"))
        #expect(failure { try generate("struct P: Codable { var f: (Int, Int) }\nstruct R: Codable {}") }
            .contains("has no TypeScript form"))
    }

    @Test func aBadTableIsRefused() {
        #expect(failure { try generate("struct P: Codable {}\nstruct R: Codable {}",
                                       extraRows: "Row(Method.one, params: P.self, result: R.self, kind: .hostRequest),") }
            .contains("test/one is in WebSignatures twice"))
        #expect(failure { try generate("struct P: Codable {}\nstruct R: Codable {}",
                                       extraRows: "Row(Method.nothing, params: P.self, result: R.self, kind: .hostRequest),") }
            .contains("is not a DaemonAPI method or notification constant"))
    }
}
