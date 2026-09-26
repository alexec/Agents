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

    /// Codex (047): no `_meta` and no flags, one variable holding the feature switches as
    /// JSON, the same text every launch, and ChatGPT offered first.
    @Test func codexSendsItsFeatureSwitchesInCodexConfig() throws {
        let policy = ToolPolicyCatalog.codex
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.launchEnvironment == ["CODEX_CONFIG":
            #"{"features":{"apps":false,"default_mode_request_user_input":true,"goals":false,"in_app_local_automation":false,"memories":false,"multi_agent":false,"sleep_tool":false}}"#])
        #expect(policy.escalationTool == "request_user_input")
        #expect(policy.kept.map(\.name) == ["request_user_input"])
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

    /// Antigravity (049): a deny list at `_meta.agy.disabledTools`, exactly as the server
    /// documents it, taking only `start_subagent` and never the question tool.
    @Test func antigravitySendsADenyListUnderAgy() throws {
        let policy = ToolPolicyCatalog.antigravity
        let meta = try #require(policy.sessionMeta)
        #expect(meta == .object(["agy": .object(["disabledTools": .array([.string("start_subagent")])])]))
        #expect(policy.escalationTool == "ask_question")
        #expect(policy.kept.map(\.name) == ["ask_question"])
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.environmentFiles.isEmpty)
        #expect(policy.preferredAuthMethods.first == "oauth-personal", "a Google account first (049 D3)")
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

    /// On a server (047, research T008): Codex never offers ChatGPT, and a lent key comes with
    /// a home of the app's own that keeps the sign-in in memory. On the Mac, neither.
    @Test func onAServerCodexGetsNoBrowserAndAnEphemeralHomeWhenAKeyIsLent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let base = ["PATH": "/usr/bin"]
        let policy = ToolPolicyCatalog.codex

        let mac = ProcessSessionLauncher.environment(for: policy, locations: locations, onto: base)
        #expect(mac["NO_BROWSER"] == nil && mac["CODEX_HOME"] == nil && mac["DEFAULT_AUTH_REQUEST"] == nil)

        let ownSignIn = ProcessSessionLauncher.environment(for: policy, locations: locations, onto: base, onServer: true)
        #expect(ownSignIn["NO_BROWSER"] == "1")
        #expect(ownSignIn["CODEX_HOME"] == nil, "a server's own sign-in lives in its own ~/.codex")

        let lent = LentEnvironment.$value.withValue(["CODEX_API_KEY": "sk-proj-test"]) {
            ProcessSessionLauncher.environment(for: policy, locations: locations, onto: base, onServer: true)
        }
        #expect(lent["NO_BROWSER"] == "1")
        #expect(lent["DEFAULT_AUTH_REQUEST"] == #"{"methodId":"api-key"}"#)
        let home = try #require(lent["CODEX_HOME"])
        #expect(home == root.appendingPathComponent("runtimes/codex-home").path)
        #expect(try String(contentsOfFile: home + "/config.toml", encoding: .utf8)
                == "cli_auth_credentials_store = \"ephemeral\"\n")
        let mode = try FileManager.default.attributesOfItem(atPath: home)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home) == ["config.toml"],
                "the app writes the config and nothing else there")

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

    /// Gemini: nothing in `_meta`, no flags of its own, and one file whose path follows
    /// `--policy`. One deny rule per category, each saying what to use instead.
    @Test func geminiIsSentAPolicyFile() throws {
        let policy = ToolPolicyCatalog.gemini
        #expect(policy.lever == .file)
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.escalationTool == nil)
        let file = try #require(policy.environmentFiles.first)
        #expect(policy.environmentFiles.count == 1)
        #expect(file.argument == "--policy" && file.variable == nil)
        #expect(file.contents == """
            # Written by the Agents app. Do not edit: rebuilt on every launch.

            [[rule]]
            toolName = ["tracker_create_task", "tracker_update_task", "tracker_get_task", "tracker_list_tasks", "tracker_add_dependency", "tracker_visualize"]
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

    @Test func aFileNamedByAnArgumentIsWrittenAndPassed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RuntimePolicyFiles(locations: StoreLocations(root: root))

        let path = root.appendingPathComponent("runtimes/gemini-policy.toml").path
        #expect(files.arguments(for: ToolPolicyCatalog.gemini) == ["--policy", path])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == ToolPolicyCatalog.gemini.environmentFiles[0].contents)
        // And it is not also put in the environment, which is Grok's way, not Gemini's.
        #expect(files.environment(for: ToolPolicyCatalog.gemini, onto: ["PATH": "/usr/bin"]) == ["PATH": "/usr/bin"])
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
            #expect(ProcessSessionLauncher.capabilities(for: policy) == .app, "\(policy.runtimeID)")
        }
    }

    /// Claude's own worktree tools would move a session where the app cannot follow (053).
    @Test func claudeCannotMoveItselfExceptThroughTheApp() throws {
        let meta = try #require(ToolPolicyCatalog.claude.sessionMeta)
        let names = try #require(meta["claudeCode"]?["options"]?["disallowedTools"]?.arrayValue).compactMap(\.stringValue)
        #expect(names.contains("EnterWorktree"))
        #expect(names.contains("ExitWorktree"))
        #expect(RemitCategory.workingFolder.instead.contains(AppTool.enterWorktree))
    }
}
