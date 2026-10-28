import Foundation

/// The words every runtime shares (#2658): one set for each field, so a pill under the prompt
/// says its value only, and the same value means the same on every runtime. One place, so
/// the Mac, the Remote and the web page (from `levels/words.json`) agree.
public enum LevelWords {
    /// The runtime choice that is not a runtime.
    public static let auto = "Auto"
    public static let autoID = "auto"

    // Fields, as a menu's header names them.
    public static let modelField = "Model"
    public static let permissionField = "Permission mode"
    public static let requestsField = "Permission requests"
    public static let sandboxField = "Sandbox"
    public static let runtimeField = "Runtime"

    public static func model(_ level: ModelLevel) -> String {
        switch level {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .smart: "Smart"
        }
    }

    public static func permission(_ level: PermissionLevel) -> String {
        switch level {
        case .plan: "Plan"
        case .ask: "Ask"
        case .approveForMe: "Approve for me"
        }
    }

    public static func requests(_ mode: ClientPermissionMode) -> String {
        switch mode {
        case .default: "Request cards"
        case .alwaysApprove: "Yes to all"
        }
    }

    public static func sandbox(_ choice: SandboxChoice) -> String {
        switch choice {
        case .runtime: "Default sandbox"
        case .on: "Runtime sandbox"
        case .off: "No sandbox"
        }
    }

    /// What each value means, on every runtime: the line under it in a menu.
    public static func meaning(model level: ModelLevel) -> String {
        switch level {
        case .fast: "The runtime’s smallest and quickest model that can do the work."
        case .balanced: "Its usual model."
        case .smart: "Its most capable model."
        }
    }

    public static func meaning(permission level: PermissionLevel) -> String {
        switch level {
        case .plan: "Reads and plans; cannot change files or run commands that change things."
        case .ask: "Asks before it changes things."
        case .approveForMe: "Does not ask for normal changes in its folder."
        }
    }

    public static func meaning(requests mode: ClientPermissionMode) -> String {
        switch mode {
        case .default: "Each permission request is a card for you."
        case .alwaysApprove: "The app says yes to each permission request."
        }
    }

    public static func meaning(sandbox choice: SandboxChoice) -> String {
        switch choice {
        case .runtime: "The runtime’s own settings decide."
        case .on: "The app turns the runtime’s sandbox on."
        case .off: "Commands run with your own access."
        }
    }

    /// A pill whose agent runs with its runtime's own value, which matches no shared one.
    public static let custom = "Custom"
    /// The mark on the value that Settings gives, when the agent has no choice of its own.
    public static let followsSettings = "follows Settings"

    /// The menu of a runtime's own choices, behind the shared ones.
    public static func own(_ runtimeName: String) -> String { "⋯ \(runtimeName)’s own" }

    /// A value in a menu, said as it is on the runtime: "Balanced: Sonnet 5 on Claude".
    public static func on(_ value: String, native: String, runtimeName: String) -> String {
        "\(value): \(native) on \(runtimeName)"
    }

    // Auto in the chooser and the header.

    /// The chooser's line under Auto: the runtime it picks now.
    public static func picks(_ runtimeName: String?) -> String {
        guard let runtimeName else { return "No runtime can start now" }
        return "Picks \(runtimeName) now"
    }

    public static let noneIncluded = "No runtime included"
    /// The form's chooser, on the Remote: "Auto (Claude)".
    public static func autoRow(_ runtimeName: String?) -> String {
        guard let runtimeName else { return auto }
        return "\(auto) (\(runtimeName))"
    }

    /// An Auto agent's header: "Auto · Claude".
    public static func header(_ runtimeName: String) -> String { "\(auto) · \(runtimeName)" }

    /// The line over the prompt when no runtime can take it: "Claude: out; Codex: not signed in".
    public static func noRuntime(_ skipped: [AutoSkip], name: (String) -> String) -> String {
        guard !skipped.isEmpty else { return "No runtime can take this session." }
        return skipped.map { "\(name($0.runtimeID)): \($0.reason)" }.joined(separator: "; ")
    }

    public static let openAutoSettings = "Auto settings"

    // Settings ▸ Agent Runtimes ▸ Auto.

    public static let runtimesTitle = "Runtimes"
    public static let runtimesFooter = "Auto tries the included runtimes in this order, and starts the session on the first that can take it. A rate-limited one is tried last."
    public static let include = "Include"
    public static let mappingsTitle = "Mappings"
    public static let mappingsFooter = "What each value is on each runtime. Click a cell to choose one of the runtime’s own settings."
    public static let reset = "Reset"

    public static func field(_ field: AutoField) -> String {
        switch field {
        case .model: modelField
        case .permission: permissionField
        case .permissionRequests: requestsField
        case .sandbox: sandboxField
        }
    }

    /// The values of a field, in order, by their wire names.
    public static func levels(_ field: AutoField) -> [String] {
        switch field {
        case .model: ModelLevel.allCases.map(\.rawValue)
        case .permission: PermissionLevel.allCases.map(\.rawValue)
        case .permissionRequests: [ClientPermissionMode.default.rawValue, ClientPermissionMode.alwaysApprove.rawValue]
        case .sandbox: SandboxChoice.allCases.map(\.rawValue)
        }
    }

    /// A value's words, by its wire name in a field.
    public static func level(_ field: AutoField, _ raw: String) -> String {
        switch field {
        case .model: ModelLevel(rawValue: raw).map(model) ?? raw
        case .permission: PermissionLevel(rawValue: raw).map(permission) ?? raw
        case .permissionRequests: ClientPermissionMode(rawValue: raw).map(requests) ?? raw
        case .sandbox: SandboxChoice(rawValue: raw).map(sandbox) ?? raw
        }
    }

    /// A cell's mark, as the table says it.
    public static func mark(_ mark: AutoMark) -> String {
        switch mark {
        case .autoMapped: "auto-mapped"
        case .nearestSafer: "nearest safer"
        case .yours: "yours"
        case .notPossible: "Not possible"
        case .dropped: "no longer offered"
        }
    }

    /// A runtime's state on the Auto page.
    public static func state(available: Bool, signedIn: Bool, out: Bool, rateLimited: Bool) -> String {
        if !available { return "Not installed" }
        if !signedIn { return "Not signed in" }
        if out { return "Out" }
        if rateLimited { return "Rate limited" }
        return "Available"
    }

    /// The button on an Auto session that ran out (FR-022).
    public static func continueOn(_ runtimeName: String) -> String { "Continue on \(runtimeName)" }

    // The words in workflow, persona and start_session files.

    public static func fileWord(_ field: AutoField, _ raw: String) -> String {
        switch (field, raw) {
        case (.permission, "approveForMe"): "approve-for-me"
        case (.permissionRequests, "default"): "request-cards"
        case (.permissionRequests, "alwaysApprove"): "yes-to-all"
        case (.sandbox, "runtime"): "default"
        case (.sandbox, "on"): "runtime"
        case (.sandbox, "off"): "none"
        default: raw
        }
    }
}

public extension Levels {
    /// The pill's words for a field: the value, or Custom when the agent's own setting
    /// matches none.
    var modelWords: String { model.map(LevelWords.model) ?? LevelWords.custom }
    var permissionWords: String { permission.map(LevelWords.permission) ?? LevelWords.custom }
}
