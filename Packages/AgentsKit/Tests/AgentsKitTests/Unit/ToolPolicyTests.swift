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
        for retired in AppTool.retiredEndOfTurn {
            #expect(!RemitCategory.suggestions.instead.contains(retired))
        }
    }

    /// The one tool this feature could break that would matter most. Every runtime the
    /// app can ask a question through keeps the thing it asks with, and says why.
    ///
    /// Held per runtime rather than over every non-empty `kept`, which is what this said
    /// when keeping a tool meant one thing: sub-agents came back for every runtime on
    /// 2026-09-29, so a runtime can now keep several tools and only one of them is the
    /// way to reach the person.
    @Test func theEscalationPathIsKeptDeliberately() {
        for policy in ToolPolicyCatalog.builtIn {
            guard let tool = policy.escalationTool else { continue }
            #expect(policy.kept.contains { $0.name == tool },
                    "\(policy.runtimeID) asks through \(tool) and does not keep it")
            #expect(policy.kept.contains { $0.because.contains("escalation path") },
                    "\(policy.runtimeID) keeps \(tool) without saying it is the escalation path")
        }
        for policy in ToolPolicyCatalog.builtIn {
            #expect(!policy.removed.contains { $0.name == "AskUserQuestion" || $0.name == "ask_user_question" })
        }
    }

    // MARK: The wire shapes

    /// Claude: a denial list, nested three keys deep, holding every removal and nothing
    /// else. The contract is `contracts/runtime-launch.md` §3. Sub-agents are on the other
    /// side of it: `Agent`, `TaskOutput` and `TaskStop` (057), then `ListAgents` and
    /// `SendMessage` with the rest (2026-09-29).
    @Test func claudeSendsADenialList() throws {
        let policy = ToolPolicyCatalog.claude
        let meta = try #require(policy.sessionMeta)
        let names = try #require(meta["claudeCode"]?["options"]?["disallowedTools"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(names == policy.removed.map(\.name))
        #expect(names.contains("ScheduleWakeup"))
        #expect(names.contains("mcp__claude_ai_Google_Drive"))
        #expect(!names.contains("AskUserQuestion"))
        for tool in ["Agent", "TaskOutput", "TaskStop", "ListAgents", "SendMessage"] {
            #expect(!names.contains(tool), "Claude's sub-agent tool \(tool) is denied")
        }
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
    }

    /// Grok: an allow list, as a profile, with the profile's own fields beside the
    /// tools rather than inside them. Sub-agents are named in it, which for an allow
    /// list is the only way they can be: unlisted means unavailable (Research R6).
    @Test func grokSendsAProfile() throws {
        let policy = ToolPolicyCatalog.grok
        let meta = try #require(policy.sessionMeta)
        let profile = try #require(meta["agentProfile"])
        let tools = try #require(profile["tools"]?.arrayValue).compactMap(\.stringValue)
        #expect(tools.contains("ask_user_question"))
        #expect(tools.contains("run_terminal_command"))
        for tool in ["spawn_subagent", "kill_command_or_subagent", "get_command_or_subagent_output"] {
            #expect(tools.contains(tool), "Grok's sub-agent tool \(tool) is missing from the profile")
        }
        #expect(policy.kept.map(\.name).allSatisfy(tools.contains(_:)),
                "a tool Grok is told we keep is not in the profile that grants it")
        #expect(profile["name"]?.stringValue == "agents-app")
        #expect(profile["description"]?.stringValue?.isEmpty == false)
        // The allow list says what to keep, so the removals are the argument for the
        // policy rather than the thing sent. They must still not appear in it.
        for removed in policy.removed { #expect(!tools.contains(removed.name)) }
        #expect(policy.launchArguments.isEmpty)
    }

    /// Copilot: flags, in order, with every removed name after one `--excluded-tools`.
    /// The sub-agent tools left it on 2026-09-29; the rival's SQL store did not.
    @Test func copilotSendsFlags() {
        let policy = ToolPolicyCatalog.copilot
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments == ["--disable-mcp-server", "software-factory",
                                           "--disable-builtin-mcps",
                                           "--excluded-tools",
                                           "session_store_sql"])
    }

    /// Cursor: nothing at all, which is the case worth a test of its own. A runtime
    /// with no lever must be sent no `_meta`, no flags and no files — not an empty one
    /// of each, which is a different message. Nothing is denied and nothing is left
    /// over, so the briefing has nothing to warn about either.
    @Test func cursorIsSentNothing() {
        let policy = ToolPolicyCatalog.cursor
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.removed.isEmpty)
        #expect(policy.residue.isEmpty)
        #expect(policy.kept.map(\.name) == ["AskQuestion", "Task", "CreateGoal", "UpdateGoal"])
        #expect(Briefing.residue(policy.residue) == nil)
    }

    /// Codex (047): no `_meta` and no flags, one variable holding the feature switches as
    /// JSON, the same text every launch, and ChatGPT offered first. `multi_agent` was
    /// already on (057) and `goals` came back with the rest of the task trackers
    /// (2026-09-29). Memory is left to Codex's own configuration.
    @Test func codexSendsItsFeatureSwitchesInCodexConfig() throws {
        let policy = ToolPolicyCatalog.codex
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.launchEnvironment == ["CODEX_CONFIG":
            #"{"features":{"apps":false,"default_mode_request_user_input":true,"goals":true,"in_app_local_automation":false,"multi_agent":true,"sleep_tool":false}}"#])
        #expect(policy.escalationTool == "request_user_input")
        #expect(policy.kept.map(\.name) == ["request_user_input", "goals"])
        #expect(policy.preferredAuthMethods == ["chat-gpt", "chat-gpt-device-code", "api-key"])
        #expect(ToolPolicyCatalog.claude.launchEnvironment.isEmpty)
    }

    @Test func codexsVariableReachesItsLaunchAndNobodyElses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let base = ["PATH": "/usr/bin", "CODEX_CONFIG": "the person's own"]
        let codex = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.codex, locations: locations, onto: base)
        #expect(codex["CODEX_CONFIG"]?.hasPrefix(#"{"features":"#) == true, "the app's switches win for its own agents")
        #expect(codex["PATH"] == "/usr/bin")
        let claude = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.claude, locations: locations, onto: base)
        #expect(claude["CODEX_CONFIG"] == "the person's own", "and nobody else's launch is touched")
    }

    /// Antigravity (049): its sub-agent tool came back on 2026-09-29, so there is nothing
    /// left to deny and nothing is sent. Not an empty `disabledTools`: that says we looked
    /// and had nothing to hide, which is not the same as saying nothing at all.
    @Test func antigravityIsSentNoMetaWhileItDeniesNothing() {
        let policy = ToolPolicyCatalog.antigravity
        #expect(policy.sessionMeta == nil)
        #expect(policy.removed.isEmpty)
        #expect(policy.lever == .sessionMetaDenyList(path: ["agy", "disabledTools"]),
                "the lever stays, for the day a rule comes back")
        #expect(policy.escalationTool == "ask_question")
        #expect(policy.kept.map(\.name) == ["ask_question", "start_subagent"])
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.preferredAuthMethods.first == "oauth-personal", "a Google account first (049 D3)")
    }

    /// And the lever itself, on a runtime that does have something to deny, at the path
    /// the server documents ("Clients pass the filter under `_meta.agy`").
    @Test func aDenyListIsSentOnlyWhenThereIsSomethingInIt() throws {
        let lever = Lever.sessionMetaDenyList(path: ["agy", "disabledTools"])
        let denying = ToolPolicy(
            runtimeID: "imaginary",
            removed: [RemovedTool(name: "start_subagent", category: .agents)],
            lever: lever)
        #expect(denying.sessionMeta == .object(["agy": .object(["disabledTools": .array([.string("start_subagent")])])]))

        let denyingNothing = ToolPolicy(runtimeID: "imaginary", lever: lever)
        #expect(denyingNothing.sessionMeta == nil)
        #expect(denyingNothing.launchArguments.isEmpty, "and no empty flag list either")
    }

    /// Its home is the daemon's, never `~/.gemini`; a key in the daemon's own environment
    /// is not handed on; and nobody else's launch changes.
    @Test func antigravityLaunchesInTheDaemonsOwnHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let base = ["PATH": "/usr/bin", "GEMINI_API_KEY": "stray", "GOOGLE_API_KEY": "stray", "HOME": "/Users/x"]
        let antigravity = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.antigravity,
                                                             locations: locations, onto: base)
        #expect(antigravity["GEMINI_HOME"] == root.path + "/runtimes/antigravity/home")
        #expect(antigravity["AGY_ACP_DISABLE_WORKSPACE_TRUST"] == "1")
        #expect(antigravity["AGY_ACP_FORCE_FILE_STORAGE"] == "1", "a sign-in the app can copy to a server (D8)")
        #expect(antigravity["GEMINI_API_KEY"] == nil)
        #expect(antigravity["GOOGLE_API_KEY"] == nil)
        #expect(antigravity["PATH"] == "/usr/bin")
        let claude = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.claude, locations: locations, onto: base)
        #expect(claude == base)
        #expect(RuntimeLaunchCatalog.antigravity.folders(root: root.path) == [root.path + "/runtimes/antigravity/home"])
    }

    /// Antigravity signs in with a Google account only (049 D3): the key and Agent Platform
    /// methods its server also offers are on no sheet, and Google comes first.
    @Test func antigravityOffersGoogleSignInOnly() throws {
        let sent = try JSONDecoder().decode([ACP.AuthMethod].self, from: Data(#"""
            [{"id":"oauth-personal","name":"Log in with Google"},{"id":"oauth-business","name":"Log in with Gemini Enterprise"},
             {"id":"gemini-api-key","name":"Gemini API key"},{"id":"agent-platform","name":"Gemini Enterprise Agent Platform"}]
            """#.utf8))
        let account = RuntimeAccount(runtimeID: "antigravity", authMethods: sent)
        #expect(account.orderedAuthMethods.map(\.id) == ["oauth-personal", "oauth-business"])
        #expect(account.preferredMethod?.id == "oauth-personal")
        // Nobody else's list changes.
        #expect(RuntimeAccount(runtimeID: "grok", authMethods: sent).orderedAuthMethods.count == 4)
    }

    /// On a server (047): Codex never offers ChatGPT. On the Mac, it does.
    @Test func onAServerCodexGetsNoBrowser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let base = ["PATH": "/usr/bin"]
        let policy = ToolPolicyCatalog.codex

        let mac = ProcessSessionLauncher.environment(for: policy, locations: locations, onto: base)
        #expect(mac["NO_BROWSER"] == nil && mac["CODEX_HOME"] == nil && mac["DEFAULT_AUTH_REQUEST"] == nil)

        let server = ProcessSessionLauncher.environment(for: policy, locations: locations, onto: base, onServer: true)
        #expect(server["NO_BROWSER"] == "1")
        #expect(server["CODEX_HOME"] == nil && server["DEFAULT_AUTH_REQUEST"] == nil,
                "a server's own sign-in lives in its own ~/.codex")

        let claude = LentEnvironment.$value.withValue(["ANTHROPIC_API_KEY": "sk-ant-api-test"]) {
            ProcessSessionLauncher.environment(for: ToolPolicyCatalog.claude, locations: locations, onto: base, onServer: true)
        }
        #expect(claude["NO_BROWSER"] == nil && claude["CODEX_HOME"] == nil)
    }

    /// Codex's methods as its handshake sent them (research R2), offered ChatGPT first;
    /// a runtime with no order keeps the old rule.
    @Test func signInMethodsFollowTheRuntimesOwnOrder() throws {
        let sent = try JSONDecoder().decode([ACP.AuthMethod].self, from: Data(#"""
            [{"id":"api-key","name":"API Key"},{"id":"chat-gpt","name":"ChatGPT"},
             {"id":"chat-gpt-device-code","name":"ChatGPT (device code)"},{"id":"gateway"}]
            """#.utf8))
        let codex = RuntimeAccount(runtimeID: "codex", authMethods: sent)
        #expect(codex.orderedAuthMethods.map(\.id) == ["chat-gpt", "chat-gpt-device-code", "api-key", "gateway"])
        #expect(codex.preferredMethod?.id == "chat-gpt")
        let other = RuntimeAccount(runtimeID: "grok", authMethods: sent)
        #expect(other.orderedAuthMethods.map(\.id) == sent.map(\.id))
        #expect(other.preferredMethod?.id == "api-key")
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

    // MARK: A file named by an argument (046)

    /// Gemini: nothing in `_meta`, no flags of its own, and no policy file either, because
    /// there is nothing to deny. `invoke_agent` and the six `tracker_*` tools came back
    /// with the rest on 2026-09-29, so a file of no rules is not written and `--policy` is
    /// not passed; the system defaults are untouched, because that file is not a policy.
    @Test func geminiIsSentNoPolicyFileWhileItDeniesNothing() throws {
        let policy = ToolPolicyCatalog.gemini
        #expect(policy.lever == .file)
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.removed.isEmpty)
        #expect(policy.escalationTool == nil)
        #expect(policy.environmentFiles.map(\.name) == ["gemini-system-defaults.json"])
        #expect(policy.environmentFiles.allSatisfy { $0.argument == nil })
        #expect(policy.kept.map(\.name) == ["invoke_agent", "tracker_create_task", "tracker_update_task",
                                           "tracker_get_task", "tracker_list_tasks", "tracker_add_dependency",
                                           "tracker_visualize"])
    }

    /// The generator behind it, on the rules it is written for: one deny rule per category,
    /// each saying what to use instead, at the top of the priority band. Held on its own
    /// now that no built-in runtime has a rule to put through it, so the day one comes back
    /// it is a name in `removed` rather than a rewrite.
    @Test func aDenyRuleIsWrittenForEachCategoryWithAReason() {
        #expect(ToolPolicyCatalog.geminiPolicy(removing: [
            RemovedTool(name: "tracker_create_task", category: .standingArrangements),
            RemovedTool(name: "tracker_visualize", category: .standingArrangements),
            RemovedTool(name: "invoke_agent", category: .agents),
        ]) == """
            # Written by the Agents app. Do not edit: rebuilt on every launch.

            [[rule]]
            toolName = ["tracker_create_task", "tracker_visualize"]
            decision = "deny"
            priority = 999
            denyMessage = "\(RemitCategory.standingArrangements.instead)"

            [[rule]]
            toolName = ["invoke_agent"]
            decision = "deny"
            priority = 999
            denyMessage = "\(RemitCategory.agents.instead)"

            """)
    }

    @Test func geminiReadsAgentsMDAfterItsOwnName() throws {
        let file = try #require(ToolPolicyCatalog.gemini.environmentFiles.first { $0.variable == "GEMINI_CLI_SYSTEM_DEFAULTS_PATH" })
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(file.contents.utf8)) as? [String: Any])
        // GEMINI.md first: Gemini's memory tool writes to the first name, and must not write
        // into the ~/.agents/AGENTS.md every agent shares.
        #expect((settings["context"] as? [String: Any])?["fileName"] as? [String] == ["GEMINI.md", "AGENTS.md"])
    }

    /// A file named by an argument is written, and its path passed after the runtime's own
    /// arguments. No built-in runtime needs one today — Gemini's only file is named by a
    /// variable — so the shape is exercised on an imaginary policy, which is what keeping
    /// it is for.
    @Test func aFileNamedByAnArgumentIsWrittenAndPassed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RuntimePolicyFiles(locations: StoreLocations(root: root))

        let imaginary = ToolPolicy(
            runtimeID: "imaginary",
            lever: .file,
            environmentFiles: [EnvironmentFile(name: "imaginary-policy.toml", contents: "# rules\n",
                                               argument: "--policy")])
        let path = root.appendingPathComponent("runtimes/imaginary-policy.toml").path
        #expect(files.arguments(for: imaginary) == ["--policy", path])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# rules\n")
        #expect(files.environment(for: imaginary, onto: ["PATH": "/usr/bin"]) == ["PATH": "/usr/bin"],
                "a file named by an argument is not also put in the environment")

        // Gemini's is named by a variable, and it passes no argument while it has no rules.
        let defaults = root.appendingPathComponent("runtimes/gemini-system-defaults.json").path
        #expect(files.environment(for: ToolPolicyCatalog.gemini, onto: ["PATH": "/usr/bin"])
                == ["PATH": "/usr/bin", "GEMINI_CLI_SYSTEM_DEFAULTS_PATH": defaults])
        #expect(files.arguments(for: ToolPolicyCatalog.gemini).isEmpty)
        // Nor does Grok's file turn into an argument.
        #expect(files.arguments(for: ToolPolicyCatalog.grok).isEmpty)
        #expect(files.arguments(for: ToolPolicyCatalog.claude).isEmpty)
    }

    /// The pin the app installs and the catalog's word for it cannot drift apart.
    @Test func geminisPinIsTheToolsetsPin() throws {
        let toolset = try Toolset.load(from: ToolsetTests.bundledGemini)
        #expect(toolset.manifest.runtimeID == RuntimeCatalog.gemini.id)
        #expect(toolset.shimName == RuntimeCatalog.gemini.executable)
        #expect(RuntimeCatalog.gemini.usesAppCopyOnly)
        #expect(RuntimeCatalog.gemini.install == .toolset(runtimeID: "gemini"))
    }

    /// Gemini reads files itself, since a missing file over ACP can never read as ENOENT to
    /// it; it still writes through the app. Nobody else changes (046).
    @Test func onlyGeminiReadsFilesItself() {
        let gemini = ProcessSessionLauncher.capabilities(for: ToolPolicyCatalog.gemini)
        #expect(!gemini.readTextFile)
        #expect(gemini.writeTextFile)
        for policy in ToolPolicyCatalog.builtIn where policy.runtimeID != RuntimeCatalog.gemini.id {
            let capabilities = ProcessSessionLauncher.capabilities(for: policy)
            #expect(capabilities.readTextFile == ACP.ClientCapabilities.app.readTextFile, "\(policy.runtimeID)")
            #expect(capabilities.writeTextFile == ACP.ClientCapabilities.app.writeTextFile, "\(policy.runtimeID)")
        }
    }

    /// Claude's own worktree tools would move a session where the app cannot follow (053).
    @Test func claudeCannotMoveItselfExceptThroughTheApp() throws {
        let meta = try #require(ToolPolicyCatalog.claude.sessionMeta)
        let names = try #require(meta["claudeCode"]?["options"]?["disallowedTools"]?.arrayValue).compactMap(\.stringValue)
        #expect(names.contains("EnterWorktree"))
        #expect(names.contains("ExitWorktree"))
        #expect(RemitCategory.workingFolder.instead.contains(AppTool.finishTurn))
        #expect(RemitCategory.workingFolder.instead.contains("leave_worktree"))
    }

    /// The relay table (056): Codex's config reads as it did in 047, Claude's relay is
    /// variables only, and a relayed run's other sign-ins go from the environment.
    @Test func relayedSignInsAreDataNotCode() throws {
        let codex = try #require(ToolPolicyCatalog.codex.relay)
        #expect(codex.config(gatePort: 4242) == "chatgpt_base_url = \"https://127.0.0.1:4242/backend-api/\"\n")
        #expect(codex.environment(gatePort: 4242, standIn: "x").isEmpty)

        let claude = try #require(ToolPolicyCatalog.claude.relay)
        #expect(claude.config(gatePort: 4242) == nil)
        #expect(claude.environment(gatePort: 4242, standIn: "sk-ant-oat01-agents-relay-standin")
                == ["ANTHROPIC_BASE_URL": "https://127.0.0.1:4242",
                    "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-agents-relay-standin"])
        for relay in [codex, claude] {
            let decoded = try JSONDecoder().decode(SignInRelay.self, from: JSONEncoder().encode(relay))
            #expect(decoded == relay)
        }

        let relayed = LentEnvironment.$value.withValue(["NODE_EXTRA_CA_CERTS": "/ca.pem", "ANTHROPIC_BASE_URL": "https://127.0.0.1:1"]) {
            LentEnvironment.applied(to: ["ANTHROPIC_API_KEY": "sk-ant-api-own", "CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/usr/bin"])
        }
        #expect(relayed["ANTHROPIC_API_KEY"] == nil && relayed["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(relayed["PATH"] == "/usr/bin" && relayed["NODE_EXTRA_CA_CERTS"] == "/ca.pem")
    }
}
