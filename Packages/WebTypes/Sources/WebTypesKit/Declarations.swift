import SwiftParser
import SwiftSyntax

/// Every type declared in the files read, by its full dotted path, with what decides its
/// JSON: stored properties and `CodingKeys` for a struct, cases for an enum, and whether its
/// coding is written by hand.
struct Declarations {
    enum Kind: Equatable {
        case `struct`, `enum`, other(String)
    }

    struct Property: Equatable {
        var name: String
        var type: String
    }

    struct Case: Equatable {
        var name: String
        var raw: String?
        var associated: [(label: String?, type: String, hasDefault: Bool)]
        static func == (a: Case, b: Case) -> Bool {
            a.name == b.name && a.raw == b.raw && a.associated.map(\.label) == b.associated.map(\.label)
                && a.associated.map(\.type) == b.associated.map(\.type)
                && a.associated.map(\.hasDefault) == b.associated.map(\.hasDefault)
        }
    }

    struct Decl {
        var path: [String]
        var kind: Kind
        var file: String
        var line: Int
        var inherits: [String] = []
        var generic = false
        var properties: [Property] = []
        var cases: [Case] = []
        /// `CodingKeys`' cases and their raw values, when the type names its keys.
        var codingKeys: [(name: String, raw: String)]?
        /// A hand-written `encode(to:)`: what goes on the wire can't be read from the
        /// properties, so the type needs an override. A hand-written `init(from:)` alone
        /// doesn't: it only reads leniently what the synthesized encoder writes.
        var customEncoder = false
        /// What that encoder writes, when its body is the plain keyed kind.
        var encodePlan: EncodePlan?
    }

    var decls: [String: Decl] = [:]
    var aliases: [String: (scope: [String], type: String)] = [:]
    /// `static let` constants with a literal value, by full path: `DaemonAPI.Method.agentsList`.
    var constants: [String: String] = [:]
    /// Paths that gained a hand-written encoder in an extension, and what it writes if that
    /// can be read.
    var customEncoderExtensions: [String: EncodePlan?] = [:]
    /// Conformances added in extensions (`extension AgentGroup: CodingKeyRepresentable`).
    var extensionConformances: [String: [String]] = [:]
    /// Every declared path, by its last component, to resolve a bare name from anywhere.
    var bySimpleName: [String: [String]] = [:]

    mutating func read(_ syntax: SourceFileSyntax, file: String) {
        let visitor = Collector(file: file, converter: SourceLocationConverter(fileName: file, tree: syntax))
        visitor.walk(syntax)
        for decl in visitor.decls {
            let key = decl.path.joined(separator: ".")
            if var existing = decls[key] {
                // A type and its extensions, or the same name declared under #if: merge.
                existing.properties += decl.properties
                existing.cases += decl.cases
                existing.customEncoder = existing.customEncoder || decl.customEncoder
                existing.encodePlan = existing.encodePlan ?? decl.encodePlan
                existing.codingKeys = existing.codingKeys ?? decl.codingKeys
                decls[key] = existing
            } else {
                decls[key] = decl
                bySimpleName[decl.path.last!, default: []].append(key)
            }
        }
        for (key, value) in visitor.aliases { aliases[key] = value }
        for (key, value) in visitor.constants { constants[key] = value }
        customEncoderExtensions.merge(visitor.customEncoderExtensions) { first, _ in first }
        extensionConformances.merge(visitor.extensionConformances) { $0 + $1 }
    }

    /// Applies what extensions said about types declared elsewhere.
    mutating func finish() {
        for (key, conformances) in extensionConformances where decls[key] != nil {
            decls[key]?.inherits += conformances
        }
        for (key, plan) in customEncoderExtensions where decls[key] != nil {
            decls[key]?.customEncoder = true
            decls[key]?.encodePlan = plan
        }
        for (key, decl) in decls {
            // `CodingKeys` is an enum nested in the type; its cases name the keys.
            if decl.codingKeys == nil, let keys = decls[key + ".CodingKeys"], keys.kind == .enum {
                decls[key]?.codingKeys = keys.cases.map { ($0.name, $0.raw ?? $0.name) }
            }
        }
    }
}

private final class Collector: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    var scope: [String] = []
    var decls: [Declarations.Decl] = []
    var aliases: [String: (scope: [String], type: String)] = [:]
    var constants: [String: String] = [:]
    var customEncoderExtensions: [String: EncodePlan?] = [:]
    var extensionConformances: [String: [String]] = [:]

    init(file: String, converter: SourceLocationConverter) {
        self.file = file
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    private func inherited(_ clause: InheritanceClauseSyntax?) -> [String] {
        clause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
    }

    private func open(_ name: String, kind: Declarations.Kind, node: some DeclSyntaxProtocol,
                      inherits: [String], generic: Bool, members: MemberBlockSyntax) {
        scope.append(name)
        var decl = Declarations.Decl(path: scope, kind: kind, file: file, line: line(node), inherits: inherits, generic: generic)
        read(members, into: &decl)
        decls.append(decl)
    }

    private func read(_ members: MemberBlockSyntax, into decl: inout Declarations.Decl) {
        read(Array(members.members), into: &decl)
    }

    /// Members, including those under `#if`, every branch of which is read.
    private func read(_ members: [MemberBlockItemSyntax], into decl: inout Declarations.Decl) {
        for member in members {
            if let condition = member.decl.as(IfConfigDeclSyntax.self) {
                for clause in condition.clauses {
                    if case .decls(let list)? = clause.elements { read(Array(list), into: &decl) }
                }
                continue
            }
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let modifiers = variable.modifiers.map(\.name.text)
                guard !modifiers.contains("static"), !modifiers.contains("class"), !modifiers.contains("lazy") else {
                    if modifiers.contains("static"), variable.bindingSpecifier.text == "let" {
                        for binding in variable.bindings {
                            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                                  let value = binding.initializer?.value else { continue }
                            if let string = value.as(StringLiteralExprSyntax.self), string.segments.count == 1,
                               let segment = string.segments.first?.as(StringSegmentSyntax.self) {
                                constants[(decl.path + [name]).joined(separator: ".")] = "\"" + segment.content.text + "\""
                            } else if let number = value.as(IntegerLiteralExprSyntax.self) {
                                constants[(decl.path + [name]).joined(separator: ".")] = number.literal.text
                            } else if let prefix = value.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
                                      let number = prefix.expression.as(IntegerLiteralExprSyntax.self) {
                                constants[(decl.path + [name]).joined(separator: ".")] = "-" + number.literal.text
                            }
                        }
                    }
                    continue
                }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    if let accessors = binding.accessorBlock {
                        // Only observers keep a property stored.
                        guard case .accessors(let list) = accessors.accessors,
                              list.allSatisfy({ ["willSet", "didSet"].contains($0.accessorSpecifier.text) }) else { continue }
                    }
                    // `let x = 1` is never decoded, so it is not a key a peer sends.
                    if variable.bindingSpecifier.text == "let", binding.initializer != nil { continue }
                    let type = binding.typeAnnotation?.type.trimmedDescription ?? "<no type>"
                    decl.properties.append(.init(name: name.trimmingCharacters(in: CharacterSet(charactersIn: "`")), type: type))
                }
            } else if let enumCase = member.decl.as(EnumCaseDeclSyntax.self) {
                for element in enumCase.elements {
                    var raw: String?
                    if let value = element.rawValue?.value {
                        if let string = value.as(StringLiteralExprSyntax.self) {
                            raw = "\"" + string.segments.trimmedDescription + "\""
                        } else {
                            raw = value.trimmedDescription
                        }
                    }
                    let associated = element.parameterClause?.parameters.map {
                        (label: $0.firstName?.text, type: $0.type.trimmedDescription, hasDefault: $0.defaultValue != nil)
                    } ?? []
                    decl.cases.append(.init(name: element.name.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                                            raw: raw, associated: associated))
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self) {
                if function.name.text == "encode", function.signature.parameterClause.parameters.first?.firstName.text == "to" {
                    decl.customEncoder = true
                    decl.encodePlan = EncodePlan.read(function)
                }
            }
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        open(node.name.text, kind: .struct, node: node, inherits: inherited(node.inheritanceClause),
             generic: node.genericParameterClause != nil, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { scope.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        open(node.name.text, kind: .enum, node: node, inherits: inherited(node.inheritanceClause),
             generic: node.genericParameterClause != nil, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        open(node.name.text, kind: .other("class"), node: node, inherits: inherited(node.inheritanceClause),
             generic: node.genericParameterClause != nil, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        open(node.name.text, kind: .other("actor"), node: node, inherits: inherited(node.inheritanceClause),
             generic: node.genericParameterClause != nil, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        scope.append(node.name.text)
        decls.append(.init(path: scope, kind: .other("protocol"), file: file, line: line(node)))
        return .skipChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.trimmedDescription.split(separator: ".").map(String.init)
        let saved = scope
        scope = extended
        stack.append(saved)
        // What an extension adds to a type declared elsewhere: cases can't be added, but a
        // hand-written coder can, and so can (computed only) properties, which don't count.
        var probe = Declarations.Decl(path: extended, kind: .other("extension"), file: file, line: line(node))
        read(node.memberBlock, into: &probe)
        if probe.customEncoder { customEncoderExtensions[extended.joined(separator: ".")] = probe.encodePlan }
        let conformances = inherited(node.inheritanceClause)
        if !conformances.isEmpty { extensionConformances[extended.joined(separator: "."), default: []] += conformances }
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { scope = stack.removeLast() }
    private var stack: [[String]] = []

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        aliases[(scope + [node.name.text]).joined(separator: ".")] = (scope, node.initializer.value.trimmedDescription)
        return .skipChildren
    }

    // Nothing inside a function or closure declares a wire type.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

import Foundation
