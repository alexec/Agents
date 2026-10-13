import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The walk for #858 (specs/858-provider-map-writer/quickstart.md), with the real default
/// runtime: a scratch control plane on this Mac (`run-app` `launch.sh --no-window`, with
/// `--control-env PATH=<Tests/Fixtures>:$PATH` for `cws`), driven as the Add Provider sheet
/// drives it. Write It for Me runs `AGENTS_WALK858_TRIES` times (5) for a server whose tools
/// don't follow the contract (`Fixtures/walk858-mcp.py`) and for Your commands (`Fixtures/cws`),
/// and Add takes each draft as the sheet would. Only when `AGENTS_WALK858_URL` is set.
///
///   AGENTS_WALK858_URL=$CONTROL_URL AGENTS_WALK858_HOME=$ROOT/control \
///   AGENTS_WALK858_TOOL=<agents-control> swift test --filter Walk858
///
/// Each line it prints starts `WALK858`; the walk's record is made from them.
@Suite("Walk #858: an agent writes a provider's tool map or commands", .serialized, .timeLimit(.minutes(90)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK858_URL"] != nil))
struct Walk858LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK858_URL"]!)! }
    var home: String { environment["AGENTS_WALK858_HOME"]! }
    var tool: String { environment["AGENTS_WALK858_TOOL"]! }
    var tries: Int { Int(environment["AGENTS_WALK858_TRIES"] ?? "") ?? 5 }
    static let secret = "s3cret-value-858"

    var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    func note(_ line: String) { print("WALK858 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A window, paired with a code from the control plane's own command.
    func window() async throws -> (ControlLink, DaemonClient) {
        let out = try run(tool, ["code", "--client", "--home", home])
        let text = try #require(out.split(separator: "\n").last { $0.hasPrefix("agents-control:2:") }).description
        let code = try #require(ControlCode(text: text))
        let id = try #require(ControlAuth.codeID(secret: code.secret))
        let key = ControlAgreement.generate()
        let client = UUID()
        let reader = try await ControlJoin.dial(url, pin: code.pin, as: .init(identity: .pairing(id), key: ControlAuth.codeKey(secret: code.secret),
                                                                            kind: "mac", controlKey: code.controlKey))
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.clientsAnnounce,
                                                            params: try JSONValue.encoding(DaemonAPI.ClientAnnounce(
                                                                id: client, publicKey: key.publicKey, name: "walk858 window", kind: .mac)))))
        _ = try await reader.next(within: 10)
        reader.close()
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: code.controlKey, client: client)
        let credentials = ControlAuth.Credentials(identity: .client(client), key: shared, kind: "mac", controlKey: code.controlKey)
        let pin = code.pin, url = self.url
        let link = ControlLink { try await ControlJoin.dial(url, pin: pin, as: credentials) }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        return (link, control)
    }

    /// Updates for every draft, as the sheet hears them.
    final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [UUID: [DaemonAPI.ProviderDraftUpdate]] = [:]
        func add(_ update: DaemonAPI.ProviderDraftUpdate) { lock.withLock { all[update.draft, default: []].append(update) } }
        private var seconds: [String: [Int]] = [:]
        func of(_ draft: UUID) -> [DaemonAPI.ProviderDraftUpdate] { lock.withLock { all[draft] ?? [] } }
        func took(_ label: String, _ value: Double) { lock.withLock { seconds[label, default: []].append(Int(value)) } }
        func times(_ label: String) -> [Int] { lock.withLock { seconds[label] ?? [] } }
    }

    struct Try {
        var seconds: Double
        var last: DaemonAPI.ProviderDraftUpdate?
        var draft: UUID
    }

    /// One press of Write It for Me, followed to its end. A start or stop question is answered
    /// no, a check question yes, as a careful person would.
    func write(_ control: DaemonClient, _ updates: Updates, _ form: DaemonAPI.ProviderAdd, secrets: [String: String]?,
               runtime: String, label: String) async throws -> Try {
        let begun = Date()
        let started = try await control.call(DaemonAPI.Method.providersDraftStart,
                                             DaemonAPI.ProviderDraftStart(form: form, secrets: secrets, runtimeID: runtime),
                                             returning: DaemonAPI.ProviderDraftStarted.self)
        if let answered = started.answered {
            note("\(label): answered with no agent: \(answered.note)")
            return Try(seconds: 0, last: nil, draft: started.draft)
        }
        var asked: Set<UUID> = []
        var seen = 0
        while Date().timeIntervalSince(begun) < 420 {
            let now = updates.of(started.draft)
            for update in now.dropFirst(seen) {
                if let step = update.steps.last { note("\(label): \(update.state) · \(step.kind.rawValue) \(step.text.prefix(160))") }
                if let question = update.question, !asked.contains(question.id) {
                    asked.insert(question.id)
                    let yes = question.kind == .check
                    note("\(label): asked “\(question.text)”, answered \(yes ? question.yes : "Don't")")
                    _ = try await control.call(DaemonAPI.Method.providersDraftAnswer,
                                               DaemonAPI.ProviderDraftAnswer(draft: started.draft, question: question.id, yes: yes))
                }
            }
            seen = now.count
            if let last = now.last, last.ended {
                let seconds = Date().timeIntervalSince(begun)
                note("\(label): \(last.state) in \(String(format: "%.0f", seconds)) s, \(last.steps.count) steps, cost \(last.cost ?? "–"), "
                     + "check \(last.check.map { $0.passed ? "passed, \($0.workspaces?.count ?? 0) listed" : "failed: \($0.problem ?? "")" } ?? "none"), "
                     + "note \(last.note ?? "–")")
                if let json = last.draftJSON, let data = try? JSONEncoder().encode(json) {
                    note("\(label): draft \(String(decoding: data, as: UTF8.self))")
                }
                updates.took(String(label.split(separator: " ").first ?? ""), seconds)
                return Try(seconds: seconds, last: last, draft: started.draft)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("\(label): no end in 7 minutes")
        _ = try? await control.call(DaemonAPI.Method.providersDraftCancel, DaemonAPI.ProviderDraftRequest(draft: started.draft))
        return Try(seconds: Date().timeIntervalSince(begun), last: updates.of(started.draft).last, draft: started.draft)
    }

    @Test func walk() async throws {
        let (link, control) = try await window()
        defer { link.disconnect() }
        let updates = Updates()
        let listening = Task {
            for await note in control.notifications() where note.method == DaemonAPI.Notification.controlProviderDraft {
                if let update = try? note.params?.decode(DaemonAPI.ProviderDraftUpdate.self) { updates.add(update) }
            }
        }
        defer { listening.cancel() }

        let runtimes = try await control.call(DaemonAPI.Method.providersRuntimes, returning: DaemonAPI.ProviderRuntimes.self)
        note("runtimes on \(runtimes.host ?? "no host"): \(runtimes.runtimes.map { "\($0.id)\($0.isDefault ? " (default)" : "")" }) \(runtimes.why ?? "")")
        let runtime = try #require(environment["AGENTS_WALK858_RUNTIME"] ?? runtimes.runtimes.first { $0.isDefault }?.id ?? runtimes.runtimes.first?.id)

        // US1: an MCP server whose tools are machines-get, machine-on and machine-off.
        let server = DaemonAPI.ProviderAdd(name: "Walk 858 Machines", kind: .stdio, command: "/usr/bin/python3",
                                           args: [fixtures.appendingPathComponent("walk858-mcp.py").path])
        let maps = try await rounds(control, updates, server, secrets: ["TEST_TOKEN": Self.secret], runtime: runtime, label: "map")
        note("SC-001: \(maps.count) of \(tries) maps added with both machines")

        // US2: Your commands, for the cws CLI.
        let commands = DaemonAPI.ProviderAdd(name: "Walk 858 cws", kind: .commands, cli: "cws")
        let configs = try await rounds(control, updates, commands, secrets: nil, runtime: runtime, label: "commands")
        note("SC-002: \(configs.count) of \(tries) configs added with both workspaces")
    }

    /// `tries` presses of Write It for Me, each draft then given to Add, as the sheet's Add does.
    /// A try passes when Add keeps it, marked as the runtime's, and it lists both workspaces.
    /// Only the last one is kept.
    func rounds(_ control: DaemonClient, _ updates: Updates, _ form: DaemonAPI.ProviderAdd, secrets: [String: String]?,
                runtime: String, label: String) async throws -> [Int] {
        var passed: [Int] = []
        var kept: ProviderID?
        // What an earlier walk left under this name.
        let listed = try await control.call(DaemonAPI.Method.providersList)["providers"]?.decode([DaemonAPI.ProviderSummary].self) ?? []
        for old in listed where old.name == form.name {
            _ = try await control.call(DaemonAPI.Method.providersRemove, DaemonAPI.ProviderRequest(id: old.id))
        }
        for n in 1...tries {
            let done = try await write(control, updates, form, secrets: secrets, runtime: runtime, label: "\(label) \(n)")
            guard done.last?.state == "done", let json = done.last?.draftJSON else { continue }
            var add = form
            if form.kind == .commands { add.commands = json } else { add.map = json }
            add.secrets = secrets
            add.draft = done.draft
            // The name is the provider's: the one before goes first.
            if let previous = kept {
                _ = try await control.call(DaemonAPI.Method.providersRemove, DaemonAPI.ProviderRequest(id: previous))
                kept = nil
            }
            do {
                let added = try await control.call(DaemonAPI.Method.providersAdd, add, returning: DaemonAPI.ProviderSummary.self)
                note("\(label) \(n): added, \(added.workspaces.map { "\($0.name) \($0.state)" })")
                if added.workspaces.count == 2 { passed.append(n) }
                kept = added.id
            } catch {
                note("\(label) \(n): Add refused: \(error)")
            }
        }
        note("\(label): passed \(passed), times \(updates.times(label))")
        #expect(passed.count == tries)
        return passed
    }
}
