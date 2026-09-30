import Foundation

/// How the app reaches each runtime's command sandbox (064), and what it says about it.
///
/// Every route here was measured under ACP, on the version named, by
/// `scripts/sandbox-probe.sh` (research R9, 2026-09-29): a real conversation asked for a
/// command that writes outside its project, and the disk said whether it could. A route
/// the probe did not confirm is not here, so the app never offers a choice it cannot
/// vouch for (FR-002). Re-measure when a runtime changes, as `acp-handshake.sh` is rerun
/// for options.
public enum SandboxCatalog {
    public enum Route: Sendable, Hashable {
        /// Arguments before the runtime's own (Grok).
        case arguments(on: [String], off: [String])
        /// Environment for the process. `nil` means the choice is not offered (Gemini's On).
        case environment(on: [String: String]?, off: [String: String])
        /// `_meta.claudeCode.options.sandbox` on every session the app opens (Claude).
        case claudeMeta
        /// The runtime's own mode: Off is Full access (Codex).
        case codexMode
        /// Nothing the app can send. The state is fixed and the sentence says why.
        case fixed(SandboxState)
    }

    public struct Entry: Sendable, Hashable {
        public let runtimeID: String
        public let route: Route
        /// The version the route was measured on, for the reference page and the next check.
        public let measuredOn: String
        /// One sentence for a runtime with no choice, or about the one it lacks (FR-013, FR-015).
        public let why: String?
        /// Text that means the runtime's sandbox could not be set up (R11), from the real
        /// failures in `Fixtures/sandbox-failures/`. Never a bare "Operation not permitted",
        /// which is also what a command denied inside a working sandbox says.
        public let failurePatterns: [String]
        /// Codex only: a failed sandbox shows in no tool call, only in the agent's reply.
        public let readsReply: Bool
        /// Gemini only: a sandbox that is on makes it hang before `initialize` (R6).
        public let hangsWhenOn: Bool
    }

    /// Seatbelt refusing to nest, as macOS says it to every runtime that uses `sandbox-exec`.
    static let seatbelt = "sandbox_apply: Operation not permitted"

    public static let entries: [Entry] = [
        Entry(runtimeID: RuntimeCatalog.claude.id, route: .claudeMeta,
              measuredOn: "Claude Code 2.1.284, adapter 0.81.2",
              why: nil,
              failurePatterns: ["Sandbox required but unavailable", seatbelt],
              readsReply: false, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.codex.id, route: .codexMode,
              measuredOn: "Codex 0.156.1, adapter 1.13.1",
              why: nil,
              failurePatterns: [seatbelt, "bwrap: No permissions to create a new namespace"],
              readsReply: true, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.grok.id,
              route: .arguments(on: ["--sandbox", "workspace"], off: ["--sandbox", "off"]),
              measuredOn: "Grok 1.0.44",
              why: nil,
              failurePatterns: ["Refusing to start with its protections missing", "sandbox initialization failed"],
              readsReply: false, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.gemini.id,
              route: .environment(on: nil, off: ["GEMINI_SANDBOX": "false"]),
              measuredOn: "Gemini CLI 0.61.0",
              why: "Gemini’s own sandbox cannot start when the app runs it, so On is not offered.",
              failurePatterns: ["failed to determine command for sandbox", "Missing sandbox command", seatbelt],
              readsReply: false, hangsWhenOn: true),
        Entry(runtimeID: RuntimeCatalog.cursor.id, route: .fixed(.runtimeControlled),
              measuredOn: "Cursor 2026.09.26",
              why: "Cursor’s own sandbox setting decides. The app cannot change it.",
              failurePatterns: [], readsReply: false, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.copilot.id, route: .fixed(.runtimeControlled),
              measuredOn: "Copilot 1.0.89-5",
              why: "Copilot’s own sandbox setting decides. The app cannot change it yet.",
              failurePatterns: [], readsReply: false, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.antigravity.id, route: .fixed(.none),
              measuredOn: "agy_acp_server 1.2.1",
              why: "Antigravity sandboxes commands only when a business account’s admin turns Sandbox mode on.",
              failurePatterns: [], readsReply: false, hangsWhenOn: false),
        Entry(runtimeID: RuntimeCatalog.opencode.id, route: .fixed(.none),
              measuredOn: "OpenCode 1.18.33",
              why: "OpenCode has no command sandbox. It asks before running commands unless set to Always-approve.",
              failurePatterns: [], readsReply: false, hangsWhenOn: false),
    ]

    public static func entry(for runtimeID: String) -> Entry? {
        entries.first { $0.runtimeID == runtimeID }
    }

    /// The choices the person may make for a runtime, `runtime` first. Empty for a runtime
    /// with no route: it shows its state and `why` instead of a control.
    public static func choices(for runtimeID: String) -> [SandboxChoice] {
        guard let route = entry(for: runtimeID)?.route else { return [] }
        switch route {
        case .arguments, .claudeMeta, .codexMode: return [.runtime, .on, .off]
        case .environment(let on, _): return on == nil ? [.runtime, .off] : [.runtime, .on, .off]
        case .fixed: return []
        }
    }

    /// Whether Off can be asked for, which is what **Continue without sandbox** needs.
    public static func canTurnOff(_ runtimeID: String) -> Bool {
        choices(for: runtimeID).contains(.off)
    }
}

extension SandboxCatalog {
    /// The state a resolved choice gives (FR-001): what the app can vouch for, and
    /// **Runtime controlled** where the runtime's own settings decide. Codex's comes from its
    /// mode whatever was asked, because the mode is its sandbox.
    public static func state(runtimeID: String, choice: SandboxChoice, codexMode: String? = nil) -> SandboxState {
        guard let entry = entry(for: runtimeID) else { return .runtimeControlled }
        switch entry.route {
        case .fixed(let state): return state
        case .codexMode: return codexMode == "agent-full-access" ? .off : .on
        case .arguments, .environment, .claudeMeta:
            switch choice {
            case .on: return .on
            case .off: return .off
            case .runtime: return .runtimeControlled
            }
        }
    }
}
