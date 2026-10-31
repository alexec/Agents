import Foundation

/// What each runtime offered the New session page last time, on each host (#1171).
///
/// The page opens on these at once, ready to send, rather than on "Asking…" until its
/// draft answers. The draft's answer still comes, and puts the rows right: a choice it
/// still offers is kept, and one it does not is let go for the runtime's own. A start
/// sent before that answer carries the chosen options, and the host applies them to the
/// session it makes.
///
/// One list for each runtime on each host, the last one heard: never more than the
/// hosts' runtimes.
public struct StartChoicesMemory: Sendable {
    private struct Key: Hashable, Sendable {
        var host: MachineRef
        var runtimeID: String
    }

    private var offered: [Key: [ConfigOption]] = [:]

    public init() {}

    /// What `runtimeID` on `host` offered last time, or nil when it has not been heard.
    public func options(for runtimeID: String, on host: MachineRef) -> [ConfigOption]? {
        offered[Key(host: host, runtimeID: runtimeID)]
    }

    /// What `runtimeID` on `host` offers now, in place of what it offered before.
    public mutating func remember(_ options: [ConfigOption], for runtimeID: String, on host: MachineRef) {
        offered[Key(host: host, runtimeID: runtimeID)] = options
    }

    public var count: Int { offered.count }

    /// The choices that stay when the rows are drawn from `options`: each one chosen that
    /// is still offered, else what the runtime has it on. A model the runtime no longer
    /// offers goes back to the runtime's own, as the Mac's form does.
    public static func kept(_ chosen: [String: JSONValue], in options: [ConfigOption]) -> [String: JSONValue] {
        var kept: [String: JSONValue] = [:]
        for option in options {
            if let choice = chosen[option.id],
               option.isBoolean || (option.options ?? []).contains(where: { $0.value == choice }) {
                kept[option.id] = choice
            } else if let current = option.currentValue {
                kept[option.id] = current
            }
        }
        return kept
    }
}
