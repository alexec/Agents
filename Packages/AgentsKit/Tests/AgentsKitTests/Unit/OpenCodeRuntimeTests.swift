import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// OpenCode as a runtime (049): only the app's copy, started with the app's settings for it
/// passed in its environment, and nothing of the person's OpenCode changed.
@Suite("OpenCode")
struct OpenCodeRuntimeTests {
    @Test func itIsTheAppsOwnCopyStartedForACPAndNeverTheDefault() {
        let runtime = RuntimeCatalog.opencode
        #expect(runtime.executable == "opencode")
        #expect(runtime.arguments == ["acp"])
        #expect(runtime.usesAppCopyOnly)
        #expect(runtime.install == .toolset(runtimeID: "opencode"))
        #expect(RuntimeCatalog.builtIn.last == runtime, "appended: builtIn[0] is the default runtime")
        #expect(RuntimeCatalog.builtIn.first == RuntimeCatalog.claude)
        #expect(!RuntimeCatalog.canMoveFolders(runtimeID: "opencode"), "it keeps working in the old folder (R9)")
    }

    /// contracts/opencode-launch.md, byte for byte.
    @Test func itsSettingsGoInOpenCodeConfigContent() {
        let policy = ToolPolicyCatalog.opencode
        #expect(policy.sessionMeta == nil)
        #expect(policy.launchArguments.isEmpty)
        #expect(policy.launchEnvironment == ["OPENCODE_CONFIG_CONTENT":
            #"{"autoupdate":false,"permission":{"bash":"ask","edit":"ask","webfetch":"ask"},"share":"disabled","tools":{"task":false}}"#])
        #expect(policy.removed.map(\.name) == ["task"])
        #expect(policy.residue.isEmpty, "inline config removes it from the model's list (R3)")
        #expect(policy.escalationTool == nil, "its question tool is off over ACP; ask_form is the way")
        #expect(policy.preferredAuthMethods == ["opencode-login"])
    }

    @Test func itsLaunchHasTheSwitchesAndNeverAStraySignIn() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ["PATH": "/usr/bin", "OPENCODE_AUTH_CONTENT": #"{"anthropic":{"type":"api","key":"x"}}"#,
                    "OPENCODE_ENABLE_QUESTION_TOOL": "1", "OPENCODE_CONFIG_CONTENT": "the person's own",
                    "ANTHROPIC_API_KEY": "the person's key"]
        let environment = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.opencode,
                                                             locations: StoreLocations(root: root), onto: base)
        #expect(environment["OPENCODE_CONFIG_CONTENT"]?.hasPrefix(#"{"autoupdate":false"#) == true)
        #expect(environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        #expect(environment["OPENCODE_DISABLE_SHARE"] == "1")
        #expect(environment["OPENCODE_AUTH_CONTENT"] == nil, "on the Mac OpenCode uses its own sign-in (D3)")
        #expect(environment["OPENCODE_ENABLE_QUESTION_TOOL"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == "the person's key", "provider keys are neither added nor removed")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["TMPDIR"] == "\(root.path)/runtimes/opencode/tmp", "a folder of its own to walk (R11)")
        #expect(RuntimeLaunchCatalog.opencode.folders(root: root.path) == ["\(root.path)/runtimes/opencode/tmp"])

        let claude = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.claude,
                                                        locations: StoreLocations(root: root), onto: base)
        #expect(claude["OPENCODE_CONFIG_CONTENT"] == "the person's own", "nobody else's launch is touched")
    }

    @Test func itReadsTheSharedSkillsAndClaudesInstructionsLinkAndWritesNothingOfItsOwn() throws {
        let rule = try #require(PersonalDotAgents.rule(for: "opencode"))
        #expect(rule.readsSharedSkills)
        #expect(rule.skillsFolder == nil)
        #expect(rule.instructionsFile == ".claude/CLAUDE.md", "measured: it follows Claude's file (R8)")
        #expect(rule.takesStdioServers)
        #expect(!rule.adopts)
    }

    // MARK: The name trap (Story 2)

    /// An `opencode` of the person's own, first on the search path, that leaves a mark if it
    /// is ever run. OpenCode reads as not on this Mac until the app's copy is whole; then the
    /// app's copy is what is found and what answers the handshake, and the mark never appears.
    @Test func anOpencodeOnThePathIsNeverFoundOrRun() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("opencode-trap-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let person = root.appendingPathComponent("person-bin", isDirectory: true)
        let mark = root.appendingPathComponent("the-persons-opencode-ran")
        try fm.createDirectory(at: person, withIntermediateDirectories: true)
        fm.createFile(atPath: person.appendingPathComponent("opencode").path,
                      contents: Data("#!/bin/sh\ntouch '\(mark.path)'\nexit 1\n".utf8),
                      attributes: [.posixPermissions: 0o700])

        let tools = root.appendingPathComponent("tools", isDirectory: true)
        var discovery = RuntimeDiscovery(searchPaths: [person.path])
        discovery.macToolsHome = tools.path
        #expect(discovery.locate(RuntimeCatalog.opencode) == .missing(lookedIn: ["\(tools.path)/opencode/current/bin"]))

        // The app's copy: a program that answers `initialize` as OpenCode does.
        let set = tools.appendingPathComponent("opencode/abc123", isDirectory: true)
        try fm.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let shim = set.appendingPathComponent("bin/opencode")
        fm.createFile(atPath: shim.path, contents: Data(Self.fakeOpenCode.utf8), attributes: [.posixPermissions: 0o700])
        #expect(discovery.locate(RuntimeCatalog.opencode) == .missing(lookedIn: ["\(tools.path)/opencode/current/bin"]),
                "not before it is marked whole")
        fm.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data())
        try fm.createSymbolicLink(atPath: tools.appendingPathComponent("opencode/current").path, withDestinationPath: "abc123")

        let found = "\(tools.path)/opencode/current/bin/opencode"
        #expect(discovery.locate(RuntimeCatalog.opencode) == .available(path: found, supportsResume: false))
        let probed = await discovery.probe(RuntimeCatalog.opencode, at: found, cwd: root)
        #expect(probed == .available(path: found, supportsResume: true))
        #expect(!fm.fileExists(atPath: mark.path), "the person's opencode was run")
    }

    /// Answers `initialize` as OpenCode 1.18.33 did (R5), and says nothing else.
    static let fakeOpenCode = #"""
        #!/usr/bin/python3
        import json, sys
        if sys.argv[1:] != ["acp"]:
            sys.exit(2)
        for line in sys.stdin:
            message = json.loads(line)
            if message.get("method") == "initialize":
                print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"resume": {}, "list": {}}},
                    "authMethods": [], "agentInfo": {"name": "OpenCode", "version": "0.0.0-fake"}}}), flush=True)
        """#

    // MARK: A zero is not a price (049 P2)

    @Test func aZeroCostFromTheWireIsNoCost() {
        #expect(Cost(wire: .object(["amount": .int(0), "currency": .string("USD")])) == nil)
        #expect(Cost(wire: .object(["amount": .double(0), "currency": .string("USD")])) == nil)
        #expect(Cost(wire: .object(["amount": .double(0.25), "currency": .string("USD")]))?.amount == Decimal(0.25))
    }

    /// OpenCode's `usage_update` on a free Zen model, as the probe recorded it (R2).
    @Test func openCodesFreeModelUsageIsUnmeasuredNotZero() throws {
        let update = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"sessionUpdate":"usage_update","used":7797,"size":200000,"cost":{"amount":0,"currency":"USD"}}
            """#.utf8))
        guard case .usage(let usage) = SessionUpdate.decode(update) else {
            Issue.record("not read as usage"); return
        }
        #expect(usage.used == 7797)
        #expect(usage.cost == nil)
    }

    @Test func aTurnReplyWithAZeroCostCarriesNone() throws {
        let usage = try JSONDecoder().decode(TurnUsage.self, from: Data(#"""
            {"totalTokens":7799,"inputTokens":5858,"outputTokens":2,"cost":{"amount":0,"currency":"USD"}}
            """#.utf8))
        #expect(usage.totalTokens == 7799)
        #expect(usage.cost == nil)
    }
}
