import Foundation
import Testing
@testable import AgentsKitCore

/// Today's Swift encoders against Packages/Wire, the schema every other language is made from
/// (#1135). The Swift `Model` types stay written by hand; this is what keeps them and the
/// schema the same. A change to a type on the wire changes `daemon.schema.json` first, then
/// `scripts/wire.sh gen` makes the Go and the TypeScript, and this test says what to change in
/// Swift by hand.
@Suite("Wire schema")
struct WireSchemaTests {
    static let wire = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Wire")
    static let fixtures = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/web")

    static func read(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: wire.appending(path: name)))
    }

    /// The records in the web fixtures, told apart by their keys, and the Swift type each is.
    struct Kind: Sendable {
        var name: String
        var matches: @Sendable ([String: JSONValue]) -> Bool
        /// Read with today's decoder and written again with today's encoder, so what is
        /// checked is the product's own output, not the fixture's.
        var encode: @Sendable (JSONValue) throws -> JSONValue
    }

    static func through<T: Codable>(_: T.Type) -> @Sendable (JSONValue) throws -> JSONValue {
        { try JSONValue.encoding(try JSONDecoder().decode(T.self, from: JSONEncoder().encode($0))) }
    }

    static func has(_ object: [String: JSONValue], _ keys: String...) -> Bool {
        keys.allSatisfy { object[$0] != nil }
    }

    static let kinds: [Kind] = [
        Kind(name: "Agent", matches: { has($0, "id", "runtimeID", "cwd", "state", "createdAt") }, encode: through(Agent.self)),
        Kind(name: "TranscriptEntry", matches: { has($0, "id", "at", "kind") && $0.count <= 5 },
             encode: through(TranscriptEntry.self)),
        Kind(name: "RuntimeStatus", matches: { has($0, "runtime", "availability") }, encode: through(RuntimeStatus.self)),
        Kind(name: "PermissionRequest", matches: { has($0, "id", "agentID", "toolCall", "options", "askedAt") },
             encode: through(PermissionRequest.self)),
        Kind(name: "WorkflowSummary", matches: { has($0, "workflow", "isEnabled", "isRunning") },
             encode: through(WorkflowSummary.self)),
    ]

    /// The types whose encoders are written by hand, by the fixture of samples of each.
    static let samples: [String: @Sendable (JSONValue) throws -> JSONValue] = [
        "ConfigOption": through(ConfigOption.self),
        "ContentBlock": through(ContentBlock.self),
        "FileReading": through(FileReading.self),
        "GitView": through(GitView.self),
        "NeedID": through(NeedID.self),
        "RuntimeAvailability": through(RuntimeAvailability.self),
        "Surface": through(Surface.self),
        "ToolCallContent": through(ToolCallContent.self),
        "WorkflowTrigger": through(WorkflowTrigger.self),
    ]

    static func walk(_ value: JSONValue, _ found: ([String: JSONValue]) -> Void) {
        switch value {
        case .object(let object):
            found(object)
            object.values.forEach { walk($0, found) }
        case .array(let array):
            array.forEach { walk($0, found) }
        default:
            break
        }
    }

    @Test func todaysEncodersWriteWhatTheSchemaSays() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        var found: [String: Int] = [:]
        var failures: [String] = []
        let files = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(!files.isEmpty, "no fixtures at \(Self.fixtures.path)")
        for file in files {
            let value = try JSONValue.parse(Data(contentsOf: file))
            if file.deletingLastPathComponent().lastPathComponent == "overrides" {
                let name = file.deletingPathExtension().lastPathComponent
                guard let encode = Self.samples[name] else {
                    Issue.record("overrides/\(name).json: no Swift type is checked against it")
                    continue
                }
                for sample in value.arrayValue ?? [] {
                    guard let input = sample["input"] else { continue }
                    failures += schema.errors(try encode(input), against: name).map { "\(name) in \(file.lastPathComponent): \($0)" }
                    found[name, default: 0] += 1
                }
                continue
            }
            Self.walk(value) { object in
                guard let kind = Self.kinds.first(where: { $0.matches(object) }) else { return }
                // A fixture the product does not read (the input of a test of a refusal,
                // say) says nothing about what it writes.
                guard let written = try? kind.encode(.object(object)) else { return }
                found[kind.name, default: 0] += 1
                failures += schema.errors(written, against: kind.name).map { "\(kind.name) in \(file.lastPathComponent): \($0)" }
            }
        }
        for name in Self.kinds.map(\.name) + Self.samples.keys.sorted() {
            #expect(found[name, default: 0] > 0, "no \(name) in the fixtures")
        }
        #expect(failures.isEmpty, "\(failures.count) records do not fit the schema:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// `personal/shared` (#1299): every reach and both skill sources, as the Swift host
    /// writes them, fit the schema the Go host is made from.
    @Test func sharedSnapshotFitsTheSchema() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        let reach: [String: DaemonAPI.Reach] = [
            "claude": .gets("sent at start"), "codex": .ownCopy("/h/.codex/config.toml"),
            "copilot": .leftOut("needs sign-in"), "cursor": .noWay("no way in"),
            "antigravity": .unchecked(nil), "grok": .unchecked("not checked yet"),
        ]
        let snapshot = DaemonAPI.SharedSnapshot(
            home: "/h/.agents", laidOut: true, runtimes: [.init(id: "claude", name: "Claude")],
            instructions: .init(path: "/h/.agents/AGENTS.md", exists: true, reach: reach),
            skills: [.init(name: "review", path: "/h/.agents/skills/review", description: "Reviews.", source: .personal,
                           clash: "/h/.claude/skills/review", reach: reach),
                     .init(name: "fmt", path: "/p/skills/fmt", description: nil, source: .plugin("tools"), clash: nil, reach: [:])],
            mcp: .init(file: "/h/.agents/mcp.json", problem: .init(message: "Not JSON.", line: 3),
                       servers: [.init(name: "docs", transport: "http", summary: "https://docs", headerNames: ["X-Key"],
                                       clash: ["codex": "/h/.codex/config.toml"], reach: reach)],
                       app: [.init(name: "agents", transport: "stdio", summary: "show_file", reach: reach)],
                       runtimeOnly: [.init(name: "own", runtimeID: "codex", file: "/h/.codex/config.toml")]),
            plugins: [.init(name: "tools", version: "1.0.0", description: nil, path: "/p",
                            contents: .init(skills: 1, commands: 2, agents: 0, hooks: 0, mcpServers: 1),
                            files: ["a.md"], serverNames: ["b"], reach: reach)],
            otherFiles: [.init(path: "personas/critic.md", kind: .persona), .init(path: "folder.json", kind: .app)],
            needsALook: [.init(kind: .clash, page: .skills, item: "review", text: "Also in ~/.claude/skills/review.")])
        #expect(schema.errors(try JSONValue.encoding(snapshot), against: "SharedSnapshot") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.SharedRequest()), against: "SharedRequest") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.SharedRequest(folder: "/p")), against: "SharedRequest") == [])
        #expect(!schema.errors(["sometimes": "x"], against: "SharedReach").isEmpty)
    }

    /// The control plane's types (#1313), which the Go control plane now takes from the
    /// schema: a sample of each, with every field set, read with today's decoder and written
    /// with today's encoder, fits the schema and comes back whole, so neither has a field
    /// the other lacks.
    @Test func controlTypesFitTheSchema() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        let samples = try JSONValue.parse(Data(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/control-wire/samples.json")))
        let types: [String: @Sendable (JSONValue) throws -> JSONValue] = [
            "ClientRecord": Self.through(ClientRecord.self),
            "ClientRequest": Self.through(DaemonAPI.ClientRequest.self),
            "ClientConnection": Self.through(DaemonAPI.ClientConnection.self),
            "ClientAnnounce": Self.through(DaemonAPI.ClientAnnounce.self),
            "MachineAnnounce": Self.through(DaemonAPI.MachineAnnounce.self),
            "Admitted": Self.through(DaemonAPI.Admitted.self),
            "ControlCodeShown": Self.through(DaemonAPI.ControlCodeShown.self),
            "MachineHello": Self.through(DaemonAPI.MachineHello.self),
            "LendSignIn": Self.through(DaemonAPI.LendSignIn.self),
            "MachineRelayRequest": Self.through(DaemonAPI.MachineRelayRequest.self),
            "RelaySwitch": Self.through(DaemonAPI.RelaySwitch.self),
            "TunnelOpen": Self.through(DaemonAPI.TunnelOpen.self),
            "ControlMoved": Self.through(DaemonAPI.ControlMoved.self),
            "ControlEndpoint": Self.through(ControlEndpoint.self),
            "ControlHello": Self.through(ControlAuth.Hello.self),
            "ControlAuth": Self.through(ControlAuth.Auth.self),
            "ControlOK": Self.through(ControlAuth.OK.self),
            "ChannelOpen": Self.through(ControlWire.ChannelOpen.self),
            "GitCredentialRequest": Self.through(DaemonAPI.GitCredentialRequest.self),
            "GitCredential": Self.through(DaemonAPI.GitCredential.self),
            "AttentionNeed": Self.through(DaemonAPI.AttentionNeed.self),
            "RelayDevices": Self.through(DaemonAPI.RelayDevices.self),
            "RelayDelivery": Self.through(DaemonAPI.RelayDelivery.self),
            "RelayCount": Self.through(DaemonAPI.RelayCount.self),
            "DetectedServer": Self.through(DaemonAPI.DetectedServer.self),
            "SSHHost": Self.through(DaemonAPI.SSHHost.self),
            "MachineInfo": Self.through(DaemonAPI.MachineInfo.self),
            "ProviderSummary": Self.through(DaemonAPI.ProviderSummary.self),
            "ProviderAdd": Self.through(DaemonAPI.ProviderAdd.self),
            "ProviderRequest": Self.through(DaemonAPI.ProviderRequest.self),
            "MachineLink": Self.through(DaemonAPI.MachineLink.self),
            "MachineOptions": Self.through(DaemonAPI.MachineOptions.self),
            "ProviderOptions": Self.through(DaemonAPI.ProviderOptions.self),
            "ProviderCreate": Self.through(DaemonAPI.ProviderCreate.self),
            "ProviderCreated": Self.through(DaemonAPI.ProviderCreated.self),
            "MachineWorkspaceCall": Self.through(DaemonAPI.MachineWorkspaceCall.self),
            "AgentMachines": Self.through(DaemonAPI.AgentMachines.self),
            "MachineSchedule": Self.through(DaemonAPI.MachineSchedule.self),
            "MachineStatus": Self.through(DaemonAPI.MachineStatus.self),
            "KeepRequest": Self.through(DaemonAPI.KeepRequest.self),
            "ProviderDraftStart": Self.through(DaemonAPI.ProviderDraftStart.self),
            "ProviderDraftStarted": Self.through(DaemonAPI.ProviderDraftStarted.self),
            "ProviderDraftRequest": Self.through(DaemonAPI.ProviderDraftRequest.self),
            "ProviderDraftAnswer": Self.through(DaemonAPI.ProviderDraftAnswer.self),
            "ProviderRuntimes": Self.through(DaemonAPI.ProviderRuntimes.self),
            "DraftStep": Self.through(DaemonAPI.DraftStep.self),
            "DraftCheck": Self.through(DaemonAPI.DraftCheck.self),
            "DraftQuestion": Self.through(DaemonAPI.DraftQuestion.self),
            "ProviderDraftUpdate": Self.through(DaemonAPI.ProviderDraftUpdate.self),
            "MachineProviderDraftCall": Self.through(DaemonAPI.MachineProviderDraftCall.self),
            "ReceiveStateRequest": Self.through(DaemonAPI.ReceiveStateRequest.self),
            "ReceiveState": Self.through(DaemonAPI.ReceiveState.self),
            "ReceiveUploadRequest": Self.through(DaemonAPI.ReceiveUploadRequest.self),
            "SentBranch": Self.through(DaemonAPI.SentBranch.self),
            "ReceiveRequest": Self.through(DaemonAPI.ReceiveRequest.self),
            "BringBackRequest": Self.through(DaemonAPI.BringBackRequest.self),
            "BringBack": Self.through(DaemonAPI.BringBack.self),
            "SendFactsRequest": Self.through(DaemonAPI.SendFactsRequest.self),
            "SendFacts": Self.through(DaemonAPI.SendFacts.self),
            "SendPackRequest": Self.through(DaemonAPI.SendPackRequest.self),
            "SendFile": Self.through(DaemonAPI.SendFile.self),
            "SendPack": Self.through(DaemonAPI.SendPack.self),
            "SendReadRequest": Self.through(DaemonAPI.SendReadRequest.self),
            "SendRead": Self.through(DaemonAPI.SendRead.self),
            "ActivityToken": Self.through(DaemonAPI.ActivityToken.self),
            // People and approve-to-join (#994).
            "ControlPerson": Self.through(DaemonAPI.ControlPerson.self),
            "SignIn": Self.through(DaemonAPI.SignIn.self),
            "PersonClient": Self.through(DaemonAPI.PersonClient.self),
            "PersonMachine": Self.through(DaemonAPI.PersonMachine.self),
            "PersonRow": Self.through(DaemonAPI.PersonRow.self),
            "PeopleList": Self.through(DaemonAPI.PeopleList.self),
            "PersonInvite": Self.through(DaemonAPI.PersonInvite.self),
            "PersonInvited": Self.through(DaemonAPI.PersonInvited.self),
            "PersonRequest": Self.through(DaemonAPI.PersonRequest.self),
            "PersonRoleRequest": Self.through(DaemonAPI.PersonRoleRequest.self),
            "PeopleChanged": Self.through(DaemonAPI.PeopleChanged.self),
            "JoinRequest": Self.through(DaemonAPI.JoinRequest.self),
            "JoinRequestDecide": Self.through(DaemonAPI.JoinRequestDecide.self),
            "JoinApproved": Self.through(DaemonAPI.JoinApproved.self),
            "JoinDecided": Self.through(DaemonAPI.JoinDecided.self),
            "MachineJoinDecision": Self.through(DaemonAPI.MachineJoinDecision.self),
            // Channel links (#1762).
            "ChannelLink": Self.through(DaemonAPI.ChannelLink.self),
            "ChannelLinkRequest": Self.through(DaemonAPI.ChannelLinkRequest.self),
            "ChannelLinkDecide": Self.through(DaemonAPI.ChannelLinkDecide.self),
            "ChannelLinkDecided": Self.through(DaemonAPI.ChannelLinkDecided.self),
            "ChannelLinkRemove": Self.through(DaemonAPI.ChannelLinkRemove.self),
            // Sign-in (#995).
            "SignInProvider": Self.through(DaemonAPI.SignInProvider.self),
            "SignInProviders": Self.through(DaemonAPI.SignInProviders.self),
            "SignInConfigure": Self.through(DaemonAPI.SignInConfigure.self),
            "SignInPair": Self.through(DaemonAPI.SignInPair.self),
            "SignInWaiting": Self.through(DaemonAPI.SignInWaiting.self),
            "SignInAdd": Self.through(DaemonAPI.SignInAdd.self),
            "SignInRemove": Self.through(DaemonAPI.SignInRemove.self),
            "SignInRequest": Self.through(DaemonAPI.SignInRequest.self),
            "SignInDecide": Self.through(DaemonAPI.SignInDecide.self),
            "SignInDecided": Self.through(DaemonAPI.SignInDecided.self),
            // Reports (#1811).
            "ReportQuery": Self.through(DaemonAPI.ReportQuery.self),
            "UsageReport": Self.through(DaemonAPI.UsageReport.self),
            "ReportExport": Self.through(DaemonAPI.ReportExport.self),
            "ReportValue": Self.through(DaemonAPI.ReportValue.self),
            "FeatureUsage": Self.through(DaemonAPI.FeatureUsage.self),
            // The user scope (#1760).
            "UserSettings": Self.through(DaemonAPI.UserSettings.self),
            "UserSettingsPart": Self.through(DaemonAPI.UserSettingsPart.self),
            "UserAgentConfig": Self.through(DaemonAPI.UserAgentConfig.self),
            "UserSecret": Self.through(DaemonAPI.UserSecret.self),
            "UserSecretRequest": Self.through(DaemonAPI.UserSecretRequest.self),
            "UserSecretNames": Self.through(DaemonAPI.UserSecretNames.self),
            "UserSettingsChanged": Self.through(DaemonAPI.UserSettingsChanged.self),
            "SecretsLeft": Self.through(DaemonAPI.SecretsLeft.self),
        ]
        let all = samples.objectValue ?? [:]
        #expect(Set(all.keys) == Set(types.keys), "a sample with no Swift type, or a type with no sample")
        for (name, sample) in all.sorted(by: { $0.key < $1.key }) {
            guard let encode = types[name] else { continue }
            let written: JSONValue
            do {
                written = try encode(sample)
            } catch {
                Issue.record("\(name): today's decoder refuses the sample: \(error)")
                continue
            }
            #expect(schema.errors(written, against: name) == [], "\(name)")
            #expect(written == sample, "\(name) does not come back whole:\n\(written)")
        }
    }

    /// The checker itself finds what is wrong, so a pass above means something.
    @Test func theCheckerRefusesWhatTheSchemaDoesNot() throws {
        let schema = try WireSchema(Self.read("daemon.schema.json"))
        let entry: [String: JSONValue] = [
            "id": "00000000-0000-0000-0000-000000000001", "at": 812_500_000,
            "kind": ["agentMessage": ["text": "hello"]],
        ]
        #expect(schema.errors(.object(entry), against: "TranscriptEntry") == [])
        var wrong = entry
        wrong["at"] = "yesterday"
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        wrong = entry
        wrong["colour"] = "blue"
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        wrong = entry
        wrong["id"] = nil
        #expect(!schema.errors(.object(wrong), against: "TranscriptEntry").isEmpty)
        // A kind this build does not know is kept whole, so any one-key object is a kind.
        #expect(schema.errors(["teleported": ["to": "Mars"]], against: "TranscriptEntryKind") == [])
        #expect(!schema.errors(["agentMessage": ["words": "hello"]], against: "TranscriptEntryKind").isEmpty)
        #expect(!schema.errors("hibernating", against: "EndedReason").isEmpty)
        #expect(!schema.errors(1.5, against: "TranscriptPage", at: "firstIndex").isEmpty)
    }

    /// WebSignatures, which the web page's tests and the grants read, and the OpenRPC documents
    /// the TypeScript is made from, name the same methods going to the same place.
    @Test func webSignaturesAreTheMethodsTaggedWeb() throws {
        var documented: [String: DaemonAPI.WebSignatures.Kind] = [:]
        for (file, request, notification) in [
            ("daemon.openrpc.json", DaemonAPI.WebSignatures.Kind.hostRequest, DaemonAPI.WebSignatures.Kind.hostNotification),
            ("control.openrpc.json", .controlRequest, .controlNotification),
        ] {
            for method in try Self.read(file)["methods"]?.arrayValue ?? [] {
                let tags = method["tags"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
                guard tags.contains("web"), let name = method["name"]?.stringValue else { continue }
                documented[name] = method["x-notification"]?.boolValue == true ? notification : request
            }
        }
        let rows = Dictionary(uniqueKeysWithValues: DaemonAPI.WebSignatures.rows.map { ($0.method, $0.kind) })
        #expect(Set(rows.keys).subtracting(documented.keys).sorted() == [], "in WebSignatures, not in Packages/Wire")
        #expect(Set(documented.keys).subtracting(rows.keys).sorted() == [], "in Packages/Wire, not in WebSignatures")
        for (method, kind) in rows where documented[method] != nil {
            #expect(documented[method] == kind, "\(method) goes to a different place")
        }
    }

    /// Capability's tables, which scripts/wire.sh gen writes, say what x-capability says on each
    /// method (#1748), and each method the web page calls or hears has one.
    @Test func capabilitiesAreWhatTheMethodsName() throws {
        for (file, table) in [("daemon.openrpc.json", Capability.host), ("control.openrpc.json", Capability.control)] {
            var named: [String: String] = [:]
            for method in try Self.read(file)["methods"]?.arrayValue ?? [] {
                guard let name = method["name"]?.stringValue else { continue }
                named[name] = method["x-capability"]?.stringValue
            }
            #expect(named == table, "\(file) and Capability disagree; run scripts/wire.sh gen")
        }
        for row in DaemonAPI.WebSignatures.rows {
            let table = [.hostRequest, .hostNotification].contains(row.kind) ? Capability.host : Capability.control
            #expect(table[row.method] != nil, "\(row.method) has no capability")
        }
    }
}

/// The part of JSON Schema draft-07 that daemon.schema.json uses, checked against a value.
struct WireSchema {
    let definitions: [String: JSONValue]

    init(_ document: JSONValue) throws {
        definitions = document["definitions"]?.objectValue ?? [:]
    }

    /// What is wrong with `value` as the definition `name` (or one of its properties).
    func errors(_ value: JSONValue, against name: String, at property: String? = nil) -> [String] {
        guard var schema = definitions[name] else { return ["no definition \(name)"] }
        if let property {
            guard let inner = schema["properties"]?[property] else { return ["\(name) has no \(property)"] }
            schema = inner
        }
        return errors(value, schema, name)
    }

    private func errors(_ value: JSONValue, _ schema: JSONValue, _ path: String) -> [String] {
        if let ref = schema["$ref"]?.stringValue {
            let name = String(ref.split(separator: "/").last ?? "")
            guard let target = definitions[name] else { return ["\(path): $ref \(ref) names nothing"] }
            return errors(value, target, path)
        }
        // A case this build does not know is kept whole and written back (x-fallback: keep);
        // a case it knows is checked as that case.
        if schema["x-fallback"]?.stringValue == "keep", let object = value.objectValue, object.count == 1,
           let cases = schema["anyOf"]?.arrayValue?.compactMap({ $0["properties"]?.objectValue?.keys.first }),
           !cases.contains(object.keys.first ?? "") {
            return []
        }
        if let options = schema["anyOf"]?.arrayValue {
            let each = options.map { errors(value, $0, path) }
            return each.contains { $0.isEmpty } ? [] : ["\(path): fits none of \(options.count) shapes (\(each.map { $0.first ?? "" }.joined(separator: "; ")))"]
        }
        if let constant = schema["const"], constant != value { return ["\(path): \(value) is not \(constant)"] }
        if let values = schema["enum"]?.arrayValue, !values.contains(value) { return ["\(path): \(value) is not one of its values"] }
        if let types = schema["type"].map({ $0.arrayValue ?? [$0] })?.compactMap(\.stringValue),
           !types.contains(where: { fits(value, $0) }) {
            return ["\(path): \(value) is not \(types.joined(separator: " or "))"]
        }
        var found: [String] = []
        switch value {
        case .object(let object):
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[required] == nil {
                found.append("\(path): \(required) is missing")
            }
            for (key, inner) in object {
                if let property = properties[key] {
                    found += errors(inner, property, "\(path).\(key)")
                } else if let more = schema["additionalProperties"] {
                    if more == .bool(false) {
                        found.append("\(path): \(key) is not in the schema")
                    } else if more["not"] != nil {
                        found.append("\(path): \(key) is not allowed")
                    } else if more != .bool(true) {
                        found += errors(inner, more, "\(path).\(key)")
                    }
                }
            }
        case .array(let array):
            if let least = schema["minItems"]?.intValue, array.count < least { found.append("\(path): fewer than \(least) items") }
            if let most = schema["maxItems"]?.intValue, array.count > most { found.append("\(path): more than \(most) items") }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() {
                    found += errors(item, items, "\(path)[\(index)]")
                }
            }
        default:
            break
        }
        return found
    }

    private func fits(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
             ("number", .int), ("number", .double), ("integer", .int):
            return true
        case ("integer", .double(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }
}
