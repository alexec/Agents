import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent is allowed to keep.
///
/// Two claims here that nothing else can make. The first is that the mapping from
/// runtime to policy is total — a runtime that arrives without one keeps every tool it
/// has, and nothing anywhere says so, which is exactly the kind of gap that is only
/// found by an agent doing something the app cannot see. The second is that the shapes
/// the table turns into are the shapes the contract says: those went down a wire to a
/// real runtime once, and nobody is sending them again to find out they still do.
@Suite("What an agent is allowed to keep")
struct ToolPolicyTests {
    // MARK: The mapping is total

    /// A new runtime cannot arrive unscoped by accident. Written the way
    /// `AgentGroupTests` writes the same idea, because it is the same idea.
    @Test func everyRuntimeHasAPolicy() {
        for runtime in RuntimeCatalog.builtIn {
            #expect(ToolPolicyCatalog.builtIn.contains { $0.runtimeID == runtime.id },
                    "\(runtime.id) has no tool policy")
        }
    }

    @Test func andEveryPolicyIsAboutARuntimeThatExists() {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(RuntimeCatalog.runtime(id: policy.runtimeID) != nil,
                    "\(policy.runtimeID) has a policy and is not a runtime")
        }
    }

    /// One a person never sees, and the reason `policy(for:)` has a fallback at all: an
    /// unknown runtime is scoped by words, not by nothing.
    @Test func aRuntimeNobodyHasScopedGetsWords() {
        let policy = ToolPolicyCatalog.policy(for: "something-new")
        #expect(policy.lever == .words)
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.removed.isEmpty)
    }

    // MARK: The table is arguable

    /// A name in two lists is a policy that contradicts itself: a tool cannot be both
    /// taken away and deliberately kept, and either of those with residue is a claim
    /// that it is gone and still there.
    @Test func noToolIsInTwoListsAtOnce() {
        for policy in ToolPolicyCatalog.builtIn {
            let removed = Set(policy.removed.map(\.name))
            let kept = Set(policy.kept.map(\.name))
            let residue = Set(policy.residue.map(\.name))
            #expect(removed.isDisjoint(with: kept), "\(policy.runtimeID)")
            #expect(removed.isDisjoint(with: residue), "\(policy.runtimeID)")
            #expect(kept.isDisjoint(with: residue), "\(policy.runtimeID)")
            #expect(removed.count == policy.removed.count, "\(policy.runtimeID) names a removal twice")
        }
    }

    @Test func nothingIsRemovedOrResidualWithoutAName() {
        for policy in ToolPolicyCatalog.builtIn {
            for tool in policy.removed { #expect(!tool.name.isEmpty) }
            for tool in policy.residue { #expect(!tool.name.isEmpty) }
            for tool in policy.kept {
                #expect(!tool.name.isEmpty)
                #expect(!tool.because.isEmpty, "\(tool.name) is kept for no stated reason")
            }
        }
    }

    /// Every category answers the question it takes away. A category with no sentence
    /// is a refusal an agent cannot act on.
    @Test func everyCategorySaysWhatToDoInstead() {
        for category in RemitCategory.allCases {
            #expect(!category.instead.isEmpty)
        }
        #expect(RemitCategory.standingArrangements.instead.contains(AppTool.manageWorkflows))
        #expect(RemitCategory.suggestions.instead.contains(AppTool.finishTurn))
        #expect(!RemitCategory.suggestions.instead.contains(AppTool.suggestPrompts))
    }

    /// The one tool this feature could break that would matter most. Every runtime the
    /// app can ask a question through keeps the thing it asks with.
    @Test func theEscalationPathIsKeptDeliberately() {
        for policy in ToolPolicyCatalog.builtIn where !policy.kept.isEmpty {
            #expect(policy.kept.contains { $0.because.contains("escalation path") },
                    "\(policy.runtimeID) keeps things but does not say which is the escalation path")
        }
        for policy in ToolPolicyCatalog.builtIn {
            #expect(!policy.removed.contains { $0.name == "AskUserQuestion" || $0.name == "ask_user_question" })
        }
    }

    // MARK: The wire shapes

    /// Claude: a denial list, nested three keys deep, holding every removal and nothing
    /// else. The contract is `contracts/runtime-launch.md` §3.
    @Test func claudeSendsADenialList() throws {
        let policy = ToolPolicyCatalog.claude
        let meta = try #require(policy.sessionMeta)
        let names = try #require(meta["claudeCode"]?["options"]?["disallowedTools"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(names == policy.removed.map(\.name))
        #expect(names.contains("ScheduleWakeup"))
        #expect(names.contains("mcp__claude_ai_Google_Drive"))
        #expect(!names.contains("AskUserQuestion"))
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
    }

    /// Grok: an allow list, as a profile, with the profile's own fields beside the
    /// tools rather than inside them.
    @Test func grokSendsAProfile() throws {
        let policy = ToolPolicyCatalog.grok
        let meta = try #require(policy.sessionMeta)
        let profile = try #require(meta["agentProfile"])
        let tools = try #require(profile["tools"]?.arrayValue).compactMap(\.stringValue)
        #expect(tools.contains("ask_user_question"))
        #expect(tools.contains("run_terminal_command"))
        #expect(!tools.contains("spawn_subagent"))
        #expect(profile["name"]?.stringValue == "agents-app")
        #expect(profile["description"]?.stringValue?.isEmpty == false)
        // The allow list says what to keep, so the removals are the argument for the
        // policy rather than the thing sent. They must still not appear in it.
        for removed in policy.removed { #expect(!tools.contains(removed.name)) }
        #expect(policy.launchArguments.isEmpty)
    }

    /// Copilot: flags, in order, with every removed name after one `--excluded-tools`.
    @Test func copilotSendsFlags() {
        let policy = ToolPolicyCatalog.copilot
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments == ["--disable-mcp-server", "software-factory",
                                           "--disable-builtin-mcps",
                                           "--excluded-tools",
                                           "task", "list_agents", "read_agent",
                                           "write_agent", "session_store_sql"])
    }

    /// Cursor: nothing at all, which is the case worth a test of its own. A runtime
    /// with no lever must be sent no `_meta`, no flags and no files — not an empty one
    /// of each, which is a different message.
    @Test func cursorIsSentNothing() {
        let policy = ToolPolicyCatalog.cursor
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.removed.isEmpty)
    }

    /// A flag that repeats per name, which no runtime needs today and which the shape
    /// exists to allow. Worth holding, because the alternative is finding out on the
    /// day a runtime does.
    @Test func aFlagCanRepeatPerName() {
        let policy = ToolPolicy(
            runtimeID: "imaginary",
            removed: [RemovedTool(name: "one", category: .agents),
                      RemovedTool(name: "two", category: .agents)],
            lever: .launchArguments(flag: "--no", repeatsFlag: true, extra: ["--first"]))
        #expect(policy.launchArguments == ["--first", "--no", "one", "--no", "two"])
    }

    // MARK: Finding a residual tool

    /// Matched on the end of the name, because a runtime may prefix it.
    @Test func residueIsFoundThroughARuntimesOwnPrefix() {
        let policy = ToolPolicyCatalog.grok
        #expect(policy.residual(matching: "workflow")?.name == "workflow")
        #expect(policy.residual(matching: "mcp__something__workflow")?.name == "workflow")
        #expect(policy.residual(matching: "monitor")?.category == .standingArrangements)
    }

    /// And not on a name that merely contains it. `workflow_settings` is somebody
    /// else's tool.
    @Test func andNotOnATheNameHappensToContain() {
        let policy = ToolPolicyCatalog.grok
        #expect(policy.residual(matching: "workflow_settings") == nil)
        #expect(policy.residual(matching: "workflows") == nil)
        #expect(ToolPolicyCatalog.claude.residual(matching: "workflow") == nil)
    }

    // MARK: The one file the app writes

    /// Written under the daemon's root, pointed at by the environment, and rebuilt
    /// every time. A second daemon on a second root gets its own.
    @Test func theOverlayIsWrittenUnderTheRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RuntimePolicyFiles(locations: StoreLocations(root: root))

        let environment = files.environment(for: ToolPolicyCatalog.grok, onto: ["PATH": "/usr/bin"])
        let path = try #require(environment["GROK_CONFIG_PATH"])
        #expect(path == root.appendingPathComponent("runtimes/grok-overlay.toml").path)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("image_gen = false"))

        // Twice is the ordinary case: every launch rewrites it.
        _ = files.environment(for: ToolPolicyCatalog.grok, onto: [:])
        #expect(FileManager.default.fileExists(atPath: path))

        let directory = root.appendingPathComponent("runtimes", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["grok-overlay.toml"])
    }

    @Test func andNothingIsWrittenForARuntimeThatNeedsNoFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RuntimePolicyFiles(locations: StoreLocations(root: root))

        for policy in [ToolPolicyCatalog.claude, ToolPolicyCatalog.copilot, ToolPolicyCatalog.cursor] {
            #expect(files.environment(for: policy, onto: ["PATH": "/usr/bin"]) == ["PATH": "/usr/bin"])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
