import SwiftSyntax

/// What a hand-written `encode(to:)` writes, read from its body when it is the plain kind: one
/// keyed container, and `encode`/`encodeIfPresent` of a value for each key (071, research R6).
/// A key written only inside an `if`, a loop or a `switch`, or with `encodeIfPresent`, is
/// optional. Anything else (a single value, an unkeyed or nested container, encoding
/// delegated to another value) can't be read, and the type needs an override.
struct EncodePlan: Equatable {
    struct Entry: Equatable {
        /// The key's case in the keys enum.
        var key: String
        /// The value encoded, as written: `id`, `self.title`, `rawState ?? state.rawValue`.
        var value: String
        var ifPresent: Bool
        var conditional: Bool
    }

    /// The keys enum the container is keyed by, as written (`CodingKeys`).
    var keys: String
    var entries: [Entry]

    static func read(_ function: FunctionDeclSyntax) -> EncodePlan? {
        guard let body = function.body else { return nil }
        let text = body.description
        for refused in ["singleValueContainer", "unkeyedContainer", "nestedContainer", "superEncoder", "encode(to:"] {
            if text.contains(refused) { return nil }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(body)
        // Containers keyed by AnyKey carry fields this build doesn't know through unchanged;
        // they add nothing a client can rely on.
        let keyed = finder.containers.filter { $0.value != "AnyKey" }
        guard keyed.count == 1, let (variable, keys) = keyed.first else { return nil }
        var entries: [Entry] = []
        for call in finder.calls where call.container == variable {
            guard let existing = entries.firstIndex(where: { $0.key == call.entry.key }) else {
                entries.append(call.entry)
                continue
            }
            // Written in two places (both branches of an `if`): optional unless both say not.
            entries[existing].conditional = entries[existing].conditional && call.entry.conditional
        }
        guard !entries.isEmpty, finder.calls.allSatisfy({ finder.containers[$0.container] != nil }) else { return nil }
        return EncodePlan(keys: keys, entries: entries)
    }

    private final class Finder: SyntaxVisitor {
        /// Container variable → the keys type it is keyed by.
        var containers: [String: String] = [:]
        var calls: [(container: String, entry: Entry)] = []

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                      call.calledExpression.trimmedDescription.hasSuffix(".container"),
                      let argument = call.arguments.first, argument.label?.text == "keyedBy" else { continue }
                let keys = argument.expression.trimmedDescription
                containers[name] = keys.hasSuffix(".self") ? String(keys.dropLast(5)) : keys
            }
            return .visitChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  ["encode", "encodeIfPresent"].contains(member.declName.baseName.text),
                  let base = member.base?.trimmedDescription,
                  node.arguments.count == 2,
                  let value = node.arguments.first?.expression.trimmedDescription,
                  let keyArgument = node.arguments.last, keyArgument.label?.text == "forKey" else { return .visitChildren }
            let key = keyArgument.expression.trimmedDescription
            guard key.hasPrefix("."), !key.dropFirst().contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" }) else {
                // A key made at run time: not a fixed shape.
                calls.append((base, Entry(key: "?", value: value, ifPresent: false, conditional: true)))
                return .visitChildren
            }
            calls.append((base, Entry(key: String(key.dropFirst()), value: value,
                                      ifPresent: member.declName.baseName.text == "encodeIfPresent",
                                      conditional: Self.isConditional(node))))
            return .visitChildren
        }

        static func isConditional(_ node: some SyntaxProtocol) -> Bool {
            var parent = node.parent
            while let current = parent {
                if current.is(FunctionDeclSyntax.self) { return false }
                if current.is(IfExprSyntax.self) || current.is(GuardStmtSyntax.self) || current.is(ForStmtSyntax.self)
                    || current.is(WhileStmtSyntax.self) || current.is(SwitchExprSyntax.self)
                    || current.is(TernaryExprSyntax.self) {
                    return true
                }
                parent = current.parent
            }
            return false
        }
    }
}
