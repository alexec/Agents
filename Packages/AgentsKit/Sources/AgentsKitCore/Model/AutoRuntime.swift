import Foundation

// The Auto runtime and the shared words (#2658): the types of Packages/Wire's AutoField,
// AutoMapping, AutoMappings, AutoMark, AutoNativeChoice, AutoOverride, AutoPick, AutoPreview,
// AutoPreviewRequest, AutoSettings, AutoSkip, Levels, ModelLevel, NativeSetting,
// PermissionLevel, SetClientPermissionRequest and SetLevelsRequest.

/// Fast, Balanced or Smart: the runtime's smallest quick model, its usual one, its most
/// capable one.
public enum ModelLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case fast, balanced, smart

    /// A value this build does not know reads as Balanced.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModelLevel(rawValue: raw) ?? .balanced
    }
}

/// Plan, Ask, Approve for me or Bypass Permissions.
public enum PermissionLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case plan, ask, approveForMe, bypassPermissions

    /// A value this build does not know reads as Ask.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PermissionLevel(rawValue: raw) ?? .ask
    }
}

/// The values a session asks for in the shared words.
public struct Levels: Codable, Sendable, Hashable {
    public var model: ModelLevel?
    public var permission: PermissionLevel?
    public var permissionRequests: ClientPermissionMode?

    public init(model: ModelLevel? = nil, permission: PermissionLevel? = nil, permissionRequests: ClientPermissionMode? = nil) {
        self.model = model
        self.permission = permission
        self.permissionRequests = permissionRequests
    }
}

/// A runtime's own setting for one value.
public struct NativeSetting: Codable, Sendable, Hashable {
    public var options: [String: JSONValue]?
    public var sandbox: SandboxChoice?
    public var clientPermission: ClientPermissionMode?

    public init(options: [String: JSONValue]? = nil, sandbox: SandboxChoice? = nil, clientPermission: ClientPermissionMode? = nil) {
        self.options = options
        self.sandbox = sandbox
        self.clientPermission = clientPermission
    }
}

public enum AutoField: String, Codable, Sendable, Hashable, CaseIterable {
    case model, permission, permissionRequests, sandbox
}

public enum AutoMark: String, Codable, Sendable, Hashable {
    case autoMapped, nearestSafer, yours, notPossible, dropped

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AutoMark(rawValue: raw) ?? .autoMapped
    }
}

/// One cell of the Mappings: what a value is on one runtime.
public struct AutoMapping: Codable, Sendable, Hashable {
    public var runtimeID: String
    public var field: AutoField
    public var level: String
    public var native: NativeSetting?
    public var words: String
    public var mark: AutoMark
    public var note: String?

    public init(runtimeID: String, field: AutoField, level: String, native: NativeSetting? = nil, words: String,
                mark: AutoMark, note: String? = nil) {
        self.runtimeID = runtimeID
        self.field = field
        self.level = level
        self.native = native
        self.words = words
        self.mark = mark
        self.note = note
    }
}

/// One of a runtime's own settings a cell can be set to.
public struct AutoNativeChoice: Codable, Sendable, Hashable {
    public var runtimeID: String
    public var field: AutoField
    public var native: NativeSetting
    public var words: String

    public init(runtimeID: String, field: AutoField, native: NativeSetting, words: String) {
        self.runtimeID = runtimeID
        self.field = field
        self.native = native
        self.words = words
    }
}

/// auto/mappings.
public struct AutoMappings: Codable, Sendable, Hashable {
    public var cells: [AutoMapping]
    public var choices: [AutoNativeChoice]

    public init(cells: [AutoMapping] = [], choices: [AutoNativeChoice] = []) {
        self.cells = cells
        self.choices = choices
    }

    /// The cell for a runtime, field and value.
    public func cell(_ runtimeID: String, _ field: AutoField, _ level: String) -> AutoMapping? {
        cells.first { $0.runtimeID == runtimeID && $0.field == field && $0.level == level }
    }

    /// The runtimes the cells are for, in the person's order.
    public var runtimeIDs: [String] {
        var out: [String] = []
        for c in cells where !out.contains(c.runtimeID) { out.append(c.runtimeID) }
        return out
    }
}

/// The person's own value for one cell.
public struct AutoOverride: Codable, Sendable, Hashable {
    public var runtimeID: String
    public var field: AutoField
    public var level: String
    public var native: NativeSetting

    public init(runtimeID: String, field: AutoField, level: String, native: NativeSetting) {
        self.runtimeID = runtimeID
        self.field = field
        self.level = level
        self.native = native
    }
}

/// Why Auto did not use a runtime.
public struct AutoSkip: Codable, Sendable, Hashable {
    public var runtimeID: String
    public var reason: String

    public init(runtimeID: String, reason: String) {
        self.runtimeID = runtimeID
        self.reason = reason
    }
}

/// On an Auto agent: the runtime picked and what it was given.
public struct AutoPick: Codable, Sendable, Hashable {
    public var runtimeID: String
    public var levels: Levels
    public var native: NativeSetting
    public var skipped: [AutoSkip]

    public init(runtimeID: String, levels: Levels, native: NativeSetting = NativeSetting(), skipped: [AutoSkip] = []) {
        self.runtimeID = runtimeID
        self.levels = levels
        self.native = native
        self.skipped = skipped
    }
}

/// The person's Auto settings: the order, the runtimes left out and their own cells.
public struct AutoSettings: Codable, Sendable, Hashable {
    public var order: [String]
    public var excluded: [String]
    public var overrides: [AutoOverride]
    public var setBy: DaemonAPI.PolicySetBy?

    public init(order: [String] = [], excluded: [String] = [], overrides: [AutoOverride] = [], setBy: DaemonAPI.PolicySetBy? = nil) {
        self.order = order
        self.excluded = excluded
        self.overrides = overrides
        self.setBy = setBy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        overrides = try c.decodeIfPresent([AutoOverride].self, forKey: .overrides) ?? []
        setBy = try c.decodeIfPresent(DaemonAPI.PolicySetBy.self, forKey: .setBy)
    }

    private enum CodingKeys: String, CodingKey { case order, excluded, overrides, setBy }

    /// These settings with a cell set to the person's own value, or back to the shipped one
    /// when `native` is nil.
    public func overriding(_ runtimeID: String, _ field: AutoField, _ level: String, with native: NativeSetting?) -> AutoSettings {
        var s = self
        s.overrides.removeAll { $0.runtimeID == runtimeID && $0.field == field && $0.level == level }
        if let native {
            s.overrides.append(AutoOverride(runtimeID: runtimeID, field: field, level: level, native: native))
        }
        return s
    }

    /// These settings with every runtime in `order`, and one included or not.
    public func including(_ runtimeID: String, _ included: Bool) -> AutoSettings {
        var s = self
        s.excluded.removeAll { $0 == runtimeID }
        if !included { s.excluded.append(runtimeID) }
        return s
    }
}

public struct AutoPreviewRequest: Codable, Sendable, Hashable {
    public var cwd: URL
    public var levels: Levels?
    public var sandbox: SandboxChoice?
    /// What the draft's attachments need the runtime to take (#3162).
    public var needs: ACP.PromptCapabilities?

    public init(cwd: URL, levels: Levels? = nil, sandbox: SandboxChoice? = nil, needs: ACP.PromptCapabilities? = nil) {
        self.cwd = cwd
        self.levels = levels
        self.sandbox = sandbox
        self.needs = needs
    }
}

/// auto/preview: the runtime Auto would pick now, or why none can.
public struct AutoPreview: Codable, Sendable, Hashable {
    public var runtimeID: String?
    public var native: NativeSetting?
    public var skipped: [AutoSkip]

    public init(runtimeID: String? = nil, native: NativeSetting? = nil, skipped: [AutoSkip] = []) {
        self.runtimeID = runtimeID
        self.native = native
        self.skipped = skipped
    }
}

public struct SetLevelsRequest: Codable, Sendable, Hashable {
    public var agentID: UUID
    public var levels: Levels

    public init(agentID: UUID, levels: Levels) {
        self.agentID = agentID
        self.levels = levels
    }
}

public struct SetClientPermissionRequest: Codable, Sendable, Hashable {
    public var agentID: UUID
    public var mode: ClientPermissionMode?

    public init(agentID: UUID, mode: ClientPermissionMode?) {
        self.agentID = agentID
        self.mode = mode
    }
}
