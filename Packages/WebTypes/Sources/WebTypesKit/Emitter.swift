import Foundation
import SwiftParser
import SwiftSyntax

/// One row of `DaemonAPI.WebSignatures`, read from its source.
struct Signature {
    enum Kind: String { case hostRequest, controlRequest, hostNotification, controlNotification }
    var method: String
    var params: TypeRef
    var result: TypeRef
    var kind: Kind
    var line: Int
}

/// Turns the declarations reachable from the signatures into TypeScript (contracts/
/// generated-types.md). Sorted by name, so the same source always gives the same bytes.
struct Emitter {
    let declarations: Declarations
    let overrides: [String: String]
    let signatures: [Signature]
    /// Where `WebSignatures` lives, which its type names are resolved from.
    let signatureScope: [String]

    struct Failure: Error, CustomStringConvertible, Equatable {
        var description: String
    }

    private var needed: [String] = []
    private var emitted: [String: String] = [:]
    private var names: [String: String] = [:]
    private var shapes: [String: (required: [String], optional: [String])] = [:]
    private var usedOverrides: Set<String> = []

    init(declarations: Declarations, overrides: [String: String], signatures: [Signature], signatureScope: [String]) {
        self.declarations = declarations
        self.overrides = overrides
        self.signatures = signatures
        self.signatureScope = signatureScope
    }

    // MARK: Names

    func tsName(_ key: String) -> String {
        var path = key.split(separator: ".").map(String.init)
        if path.count > 1, path.first == "DaemonAPI" { path.removeFirst() }
        return path.joined()
    }

    func location(_ decl: Declarations.Decl) -> String { "\(decl.file):\(decl.line)" }

    /// The declared type a name means from `scope`: the innermost enclosing match, then a
    /// bare name declared once anywhere.
    func resolve(_ path: [String], from scope: [String]) -> String? {
        var prefix = scope
        while true {
            let key = (prefix + path).joined(separator: ".")
            if declarations.decls[key] != nil || declarations.aliases[key] != nil { return key }
            if prefix.isEmpty { break }
            prefix.removeLast()
        }
        if path.count == 1, let found = declarations.bySimpleName[path[0]], found.count == 1 { return found[0] }
        if path.count == 1 {
            let aliases = declarations.aliases.keys.filter { $0.split(separator: ".").last.map(String.init) == path[0] }
            if aliases.count == 1 { return aliases[0] }
        }
        return nil
    }

    static let builtins: [String: String] = [
        "String": "string", "Character": "string", "Substring": "string",
        "Int": "number", "Int8": "number", "Int16": "number", "Int32": "number", "Int64": "number",
        "UInt": "number", "UInt8": "number", "UInt16": "number", "UInt32": "number", "UInt64": "number",
        "Double": "number", "Float": "number", "CGFloat": "number", "TimeInterval": "number", "Decimal": "number",
        "Bool": "boolean", "UUID": "UUID", "Date": "WireDate", "Data": "Base64", "URL": "URLString",
        "JSONValue": "JSONValue",
    ]

    // MARK: Types

    /// The TypeScript for a reference, queueing every declared type it names.
    mutating func ts(_ ref: TypeRef, from scope: [String], owner: String) throws -> String {
        switch ref {
        case .optional(let wrapped):
            return "\(try ts(wrapped, from: scope, owner: owner)) | null"
        case .range(let bound):
            let inner = try ts(bound, from: scope, owner: owner)
            return "[\(inner), \(inner)]"
        case .array(let element):
            let inner = try ts(element, from: scope, owner: owner)
            return inner.contains(" ") ? "(\(inner))[]" : "\(inner)[]"
        case .dictionary(let key, let value):
            if try isStringKey(key, from: scope) { return "Record<string, \(try ts(value, from: scope, owner: owner))>" }
            // A key type that is CodingKeyRepresentable goes as an object keyed by its raw value;
            // not every key need be there.
            if case .named(let path) = key, let resolved = resolve(path, from: scope),
               declarations.decls[resolved]?.inherits.contains("CodingKeyRepresentable") == true {
                let keys = try ts(key, from: scope, owner: owner)
                return "Partial<Record<\(keys), \(try ts(value, from: scope, owner: owner))>>"
            }
            throw Failure(description: "\(owner): [\(key): …] goes on the wire as an array of keys and values; "
                + "make the key CodingKeyRepresentable, give the field [String: …], or add an override")
        case .named(let path):
            if path == ["JSONValue"] { return "JSONValue" }
            guard let key = resolve(path, from: scope) else {
                if path.count == 1, let builtin = Self.builtins[path[0]] { return builtin }
                if path.count == 2, path[0] == "Foundation", let builtin = Self.builtins[path[1]] { return builtin }
                throw Failure(description: "\(path.joined(separator: ".")) is used by \(owner) but not declared in the files read")
            }
            if let alias = declarations.aliases[key] {
                return try ts(TypeRef.parse(alias.type), from: alias.scope, owner: owner)
            }
            if !needed.contains(key) { needed.append(key) }
            return tsName(key)
        }
    }

    func isStringKey(_ key: TypeRef, from scope: [String]) throws -> Bool {
        guard case .named(let path) = key else { return false }
        if let resolved = resolve(path, from: scope), let alias = declarations.aliases[resolved] {
            return try isStringKey(TypeRef.parse(alias.type), from: alias.scope)
        }
        return ["String", "Int"].contains(path.last ?? "") && resolve(path, from: scope) == nil
    }

    mutating func emit(_ key: String) throws {
        guard let decl = declarations.decls[key] else { return }
        let name = tsName(key)
        if let other = names[name], other != key {
            throw Failure(description: "\(key) and \(other) would both be \(name) in TypeScript")
        }
        names[name] = key

        if let text = overrides[name] {
            guard decl.customEncoder else {
                throw Failure(description: "Overrides/\(name).ts is not needed: \(key) has no hand-written encode(to:) "
                    + "(\(location(decl)))")
            }
            // An override never stands in for an encoder the generator can read itself.
            if decl.kind == .struct, let plan = decl.encodePlan {
                var probe = self
                if (try? probe.emit(key, decl: decl, plan: plan)) != nil {
                    throw Failure(description: "Overrides/\(name).ts is not needed: the generator reads \(key).encode(to:) "
                        + "(\(location(decl)))")
                }
            }
            usedOverrides.insert(name)
            // `// as synthesized`: the encoder is written by hand, but writes what Swift would.
            // `, defaults optional` adds that an associated value at its default is left out;
            // `// passthrough: case` that the case writes back raw JSON it couldn't read.
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            // `// as: Other` encodes through another type (often a private `Stored`): the same shape.
            if let alias = lines.first(where: { $0.hasPrefix("// as:") }) {
                let other = try ts(TypeRef.parse(String(alias.dropFirst("// as:".count))), from: decl.path,
                                   owner: "Overrides/\(name).ts")
                emitted[name] = "export type \(name) = \(other);"
                return
            }
            if let directive = lines.first(where: { $0.hasPrefix("// as synthesized") }) {
                var plain = decl
                plain.customEncoder = false
                let passthrough = Set(lines.filter { $0.hasPrefix("// passthrough:") }
                    .flatMap { $0.dropFirst("// passthrough:".count).split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                try emitPlain(key, decl: plain, defaultsOptional: directive.contains("defaults optional"),
                              passthrough: passthrough)
                return
            }
            // `// uses: A, B.C` names the Swift types the override's TypeScript mentions.
            for line in text.split(separator: "\n") where line.hasPrefix("// uses:") {
                for used in line.dropFirst("// uses:".count).split(separator: ",") {
                    _ = try ts(TypeRef.parse(String(used)), from: decl.path, owner: "Overrides/\(name).ts")
                }
            }
            emitted[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if decl.customEncoder {
            guard decl.kind == .struct, let plan = decl.encodePlan else {
                throw Failure(description: "\(key) has a hand-written encode(to:) the generator can't read (\(location(decl))); "
                    + "add Overrides/\(name).ts and a fixture")
            }
            try emit(key, decl: decl, plan: plan)
            return
        }
        try emitPlain(key, decl: decl)
    }

    /// A type whose coding Swift synthesizes.
    mutating func emitPlain(_ key: String, decl: Declarations.Decl, defaultsOptional: Bool = false,
                            passthrough: Set<String> = []) throws {
        let name = tsName(key)
        let owner = key
        let scope = decl.path
        if decl.generic { throw Failure(description: "\(key) is generic (\(location(decl)))") }

        switch decl.kind {
        case .other(let kind):
            throw Failure(description: "\(key) is a \(kind), which never goes on the wire (\(location(decl)))")
        case .struct:
            if decl.inherits.contains("RawRepresentable") {
                guard let raw = decl.properties.first(where: { $0.name == "rawValue" }) else {
                    throw Failure(description: "\(key) is RawRepresentable with no stored rawValue (\(location(decl)))")
                }
                let base = try ts(TypeRef.parse(raw.type), from: scope, owner: owner)
                emitted[name] = "export type \(name) = \(base) & { readonly __brand: \"\(name)\" };"
                return
            }
            var fields: [(key: String, property: Declarations.Property)] = []
            if let keys = decl.codingKeys {
                for (property, raw) in keys {
                    guard let found = decl.properties.first(where: { $0.name == property }) else {
                        throw Failure(description: "\(key).CodingKeys.\(property) names no stored property (\(location(decl)))")
                    }
                    fields.append((Self.unquote(raw), found))
                }
            } else {
                fields = decl.properties.map { ($0.name, $0) }
            }
            var lines: [String] = []
            var required: [String] = [], optional: [String] = []
            for (wireKey, property) in fields {
                let parsed: TypeRef
                do { parsed = try TypeRef.parse(property.type) } catch {
                    throw Failure(description: "\(key).\(property.name): \(property.type) has no TypeScript form (\(location(decl)))")
                }
                let quoted = Self.isIdentifier(wireKey) ? wireKey : "\"\(wireKey)\""
                if case .optional(let wrapped) = parsed {
                    lines.append("  \(quoted)?: \(try ts(wrapped, from: scope, owner: "\(key).\(property.name)"));")
                    optional.append(wireKey)
                } else {
                    lines.append("  \(quoted): \(try ts(parsed, from: scope, owner: "\(key).\(property.name)"));")
                    required.append(wireKey)
                }
            }
            shapes[name] = (required, optional)
            emitted[name] = lines.isEmpty ? "export interface \(name) {}"
                : "export interface \(name) {\n\(lines.joined(separator: "\n"))\n}"
        case .enum:
            guard !decl.cases.isEmpty else {
                throw Failure(description: "\(key) has no cases; it is a namespace, not a wire type (\(location(decl)))")
            }
            let rawType = decl.inherits.first.flatMap { Self.builtins[$0] }
            if rawType == "string" {
                let values = decl.cases.map { "\"\(Self.unquote($0.raw ?? $0.name))\"" }
                emitted[name] = "export type \(name) = \(values.joined(separator: " | "));"
            } else if rawType == "number" {
                var next = 0
                var values: [String] = []
                for item in decl.cases {
                    let value = item.raw.flatMap(Int.init) ?? next
                    values.append("\(value)")
                    next = value + 1
                }
                emitted[name] = "export type \(name) = \(values.joined(separator: " | "));"
            } else {
                // Swift's synthesized form: {"case": {"label": value}}, `_0` for no label.
                var members: [String] = []
                for item in decl.cases where !passthrough.contains(item.name) {
                    var payload: [String] = []
                    for (index, value) in item.associated.enumerated() {
                        let label = value.label.flatMap { $0 == "_" ? nil : $0 } ?? "_\(index)"
                        // Synthesized coding leaves a nil out (encodeIfPresent).
                        var type = try TypeRef.parse(value.type)
                        var optional = defaultsOptional && value.hasDefault
                        if case .optional(let wrapped) = type {
                            type = wrapped
                            optional = true
                        }
                        let rendered = try ts(type, from: scope, owner: "\(key).\(item.name)")
                        payload.append("\(label)\(optional ? "?" : ""): \(rendered)")
                    }
                    let body = payload.isEmpty ? "Record<string, never>" : "{ \(payload.joined(separator: "; ")) }"
                    members.append("{ \(item.name): \(body) }")
                }
                emitted[name] = "export type \(name) =\n  | \(members.joined(separator: "\n  | "));"
            }
        }
    }

    /// A struct whose `encode(to:)` is the plain keyed kind: its keys from the body, each
    /// key's type from the value encoded, or from the property named like the key.
    mutating func emit(_ key: String, decl: Declarations.Decl, plan: EncodePlan) throws {
        let name = tsName(key)
        guard let keysDecl = declarations.decls[(decl.path + [plan.keys]).joined(separator: ".")]
                ?? resolve(plan.keys.split(separator: ".").map(String.init), from: decl.path).flatMap({ declarations.decls[$0] }),
              keysDecl.kind == .enum else {
            throw Failure(description: "\(key).encode(to:) is keyed by \(plan.keys), which isn't an enum the generator found "
                + "(\(location(decl))); add Overrides/\(name).ts")
        }
        var lines: [String] = []
        var required: [String] = [], optional: [String] = []
        for entry in plan.entries {
            guard let keyCase = keysDecl.cases.first(where: { $0.name == entry.key }) else {
                throw Failure(description: "\(key).encode(to:) writes a key the generator can't name (\(entry.key)) "
                    + "(\(location(decl))); add Overrides/\(name).ts")
            }
            let wireKey = Self.unquote(keyCase.raw ?? keyCase.name)
            let plain = entry.value.hasPrefix("self.") ? String(entry.value.dropFirst(5)) : entry.value
            guard let property = decl.properties.first(where: { $0.name == plain })
                    ?? decl.properties.first(where: { $0.name == entry.key }) else {
                throw Failure(description: "\(key).encode(to:) writes \(entry.value) for \(entry.key), and no stored "
                    + "property says its type (\(location(decl))); add Overrides/\(name).ts")
            }
            var type = try TypeRef.parse(property.type)
            let isOptional = entry.ifPresent || entry.conditional
            if entry.ifPresent, case .optional(let wrapped) = type { type = wrapped }
            if isOptional, case .optional(let wrapped) = type { type = wrapped }
            // `encode` of an Optional writes null; keep that, not an absent key.
            let rendered = try ts(type, from: decl.path, owner: "\(key).\(property.name)")
            let quoted = Self.isIdentifier(wireKey) ? wireKey : "\"\(wireKey)\""
            lines.append("  \(quoted)\(isOptional ? "?" : ""): \(rendered);")
            if isOptional { optional.append(wireKey) } else { required.append(wireKey) }
        }
        shapes[name] = (required, optional)
        emitted[name] = "export interface \(name) {\n\(lines.joined(separator: "\n"))\n}"
    }

    // MARK: The file

    mutating func render() throws -> String {
        var methods: [(String, String)] = [], notifications: [(String, String)] = [], kinds: [(String, String)] = []
        for signature in signatures.sorted(by: { $0.method < $1.method }) {
            let owner = "WebSignatures \(signature.method)"
            let params = try ts(signature.params, from: signatureScope, owner: owner)
            switch signature.kind {
            case .hostRequest, .controlRequest:
                let result = try ts(signature.result, from: signatureScope, owner: owner)
                methods.append((signature.method, "{ params: \(params); result: \(result) }"))
                kinds.append((signature.method, signature.kind == .hostRequest ? "host" : "control"))
            case .hostNotification, .controlNotification:
                notifications.append((signature.method, params))
            }
        }
        var index = 0
        while index < needed.count {
            try emit(needed[index])
            index += 1
        }
        let unused = Set(overrides.keys).subtracting(usedOverrides).sorted()
        if let first = unused.first {
            throw Failure(description: "Overrides/\(first).ts is not needed: nothing on the wire reaches \(first)")
        }

        var out = """
        // GENERATED by Packages/WebTypes (agents-webtypes) from AgentsKitCore. Do not edit.
        // Regenerate: scripts/web.sh types
        //
        // Every type a method in DaemonAPI.WebSignatures reaches, read from the Swift source of
        // Packages/AgentsKit/Sources/AgentsKitCore. Hand-written shapes come from
        // Packages/WebTypes/Overrides. contracts/generated-types.md in specs/071-web-remote says how.

        /** Any JSON: JSONValue in Swift. */
        export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
        /** Upper case, as Swift's uuidString writes it. */
        export type UUID = string & { readonly __brand: "UUID" };
        /** Standard base64, with padding: Data in Swift. */
        export type Base64 = string & { readonly __brand: "Base64" };
        /** Seconds since 2001-01-01T00:00:00Z: Date in Swift, through a plain JSONEncoder. */
        export type WireDate = number & { readonly __brand: "WireDate" };
        /** An absolute URL as text: URL in Swift. */
        export type URLString = string & { readonly __brand: "URLString" };


        """
        let failures = declarations.constants
            .filter { $0.key.hasPrefix("DaemonAPI.Failure.") && Int($0.value) != nil }
            .map { (String($0.key.dropFirst("DaemonAPI.Failure.".count)), $0.value) }
            .sorted { $0.0 < $1.0 }
        out += "/** DaemonAPI.Failure: the codes a call can fail with. */\nexport const Failure = {\n"
        out += failures.map { "  \($0.0): \($0.1)," }.joined(separator: "\n") + "\n} as const;\n\n"

        for name in emitted.keys.sorted() { out += emitted[name]! + "\n\n" }

        out += "/** Every method the web remote may call: its params and its result. */\nexport interface Methods {\n"
        out += methods.map { "  \"\($0.0)\": \($0.1);" }.joined(separator: "\n") + "\n}\n\n"
        out += "/** Whether a method goes to a host (with `h`) or to the control plane itself. */\n"
        out += "export const MethodTarget = {\n" + kinds.map { "  \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
            + "\n} as const;\n\n"
        out += "/** Every notification the web remote hears, and its params. */\nexport interface Notifications {\n"
        out += notifications.map { "  \"\($0.0)\": \($0.1);" }.joined(separator: "\n") + "\n}\n\n"
        out += "/** Each interface's keys, for checking Swift-encoded fixtures against these types. */\n"
        out += "export const Shapes: Record<string, { required: readonly string[]; optional: readonly string[] }> = {\n"
        for name in shapes.keys.sorted() {
            let shape = shapes[name]!
            let required = shape.required.map { "\"\($0)\"" }.joined(separator: ", ")
            let optional = shape.optional.map { "\"\($0)\"" }.joined(separator: ", ")
            out += "  \(name): { required: [\(required)], optional: [\(optional)] },\n"
        }
        out += "};\n"
        return out
    }

    static func unquote(_ text: String) -> String {
        text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 ? String(text.dropFirst().dropLast()) : text
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" || first == "$" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }
}

/// Reads `DaemonAPI.WebSignatures.rows` from its source: each `Row(method, params: X.self,
/// result: Y.self, kind: .k)`.
enum SignatureReader {
    static func read(_ syntax: SourceFileSyntax, file: String, constants: [String: String]) throws -> [Signature] {
        let converter = SourceLocationConverter(fileName: file, tree: syntax)
        let visitor = CallCollector(viewMode: .sourceAccurate)
        visitor.walk(syntax)
        var rows: [Signature] = []
        for call in visitor.calls {
            let arguments = Array(call.arguments)
            guard arguments.count == 4, arguments[1].label?.text == "params", arguments[2].label?.text == "result",
                  arguments[3].label?.text == "kind" else { continue }
            let line = call.startLocation(converter: converter).line
            let methodText = arguments[0].expression.trimmedDescription
            guard let method = constant(methodText, in: constants) else {
                throw Emitter.Failure(description: "\(file):\(line): \(methodText) is not a DaemonAPI method or notification constant")
            }
            func type(_ argument: LabeledExprSyntax) throws -> TypeRef {
                let text = argument.expression.trimmedDescription
                guard text.hasSuffix(".self") else {
                    throw Emitter.Failure(description: "\(file):\(line): \(text) is not a Type.self")
                }
                return try TypeRef.parse(String(text.dropLast(".self".count)))
            }
            let kindText = arguments[3].expression.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let kind = Signature.Kind(rawValue: kindText) else {
                throw Emitter.Failure(description: "\(file):\(line): \(kindText) is not a row kind")
            }
            rows.append(Signature(method: Emitter.unquote(method), params: try type(arguments[1]),
                                  result: try type(arguments[2]), kind: kind, line: line))
        }
        guard !rows.isEmpty else { throw Emitter.Failure(description: "\(file) has no WebSignatures rows") }
        let methods = rows.map(\.method)
        if let twice = methods.first(where: { name in methods.filter { $0 == name }.count > 1 }) {
            throw Emitter.Failure(description: "\(twice) is in WebSignatures twice")
        }
        return rows
    }

    /// `DaemonAPI.Method.agentsList`, `Method.agentsList` or `.agentsList`, as its string.
    static func constant(_ text: String, in constants: [String: String]) -> String? {
        if let value = constants[text] { return value }
        let last = text.split(separator: ".").last.map(String.init) ?? text
        for prefix in ["DaemonAPI.Method.", "DaemonAPI.Notification."] {
            if let value = constants[prefix + last], value.hasPrefix("\"") { return value }
        }
        return nil
    }

    private final class CallCollector: SyntaxVisitor {
        var calls: [FunctionCallExprSyntax] = []
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            calls.append(node)
            return .visitChildren
        }
    }
}
