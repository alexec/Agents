import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Pinned pages (#159), through the daemon: the person's Pin, Unpin and drag, the one file
/// in the project folder, the limit, the pages read for a screen, and the pins agents made
/// before their tools went (#640). Agents are written to disk before the daemon reads it,
/// so no runtime is involved.
@Suite("Pinned pages", .timeLimit(.minutes(1)))
struct PinsTests {
    private struct Setup {
        var core: DaemonCore
        var project: URL
        var ids: [String: UUID]
    }

    private func setUp(_ names: [String]) async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPins-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        var ids: [String: UUID] = [:]
        for name in names {
            let record = Agent(runtimeID: "claude", cwd: project, title: name, state: .finished, endedReason: .endTurn)
            try await store.save(record)
            ids[name] = record.id
        }
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        return Setup(core: core, project: project, ids: ids)
    }

    private func write(_ folder: URL, _ path: String, _ text: String = "# Page\n") throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func pin(_ s: Setup, _ path: String, title: String? = nil) async throws -> [PinView] {
        try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: s.project, path: path, title: title))
    }

    private func unpin(_ s: Setup, _ path: String) async throws {
        try await s.core.unpinByPerson(DaemonAPI.PinPathRequest(folder: s.project, path: path))
    }

    private func arrange(_ s: Setup, _ paths: [String]) async throws {
        try await s.core.arrangePins(DaemonAPI.PinArrangeRequest(folder: s.project, paths: paths))
    }

    private func pinSession(_ s: Setup, _ id: UUID) async throws {
        try await s.core.pinSessionByPerson(DaemonAPI.PinSessionRequest(folder: s.project, agentID: id))
    }

    /// A pins file written as it is on disk, as an older build left it.
    private func writePinsFile(_ s: Setup, _ file: PinsFile) throws {
        try FileManager.default.createDirectory(at: s.project.appending(path: ".agents"), withIntermediateDirectories: true)
        try file.fileData().write(to: s.project.appending(path: PinsFile.path))
    }

    private func refusal(_ body: () async throws -> Any) async -> String? {
        do { _ = try await body(); return nil } catch let error as JSONRPCError { return error.message } catch { return "\(error)" }
    }

    private func pinsFile(_ s: Setup) throws -> PinsFile {
        try PinsFile.read(Data(contentsOf: s.project.appending(path: PinsFile.path))).file
    }

    @Test func thePersonPinsAPageIntoTheProjectFile() async throws {
        let s = try await setUp([])
        try write(s.project, "docs/roadmap.md")
        let views = try await pin(s, "docs/roadmap.md", title: "Roadmap")
        try #require(views.map(\.title) == ["Roadmap"])
        #expect(views[0].kind == .markdown && views[0].pinnedBy.kind == .person)
        let file = try pinsFile(s)
        #expect(file.pins == [PinEntry(path: "docs/roadmap.md", title: "Roadmap", pinnedBy: .thePerson)])
        let text = try String(contentsOf: s.project.appending(path: PinsFile.path), encoding: .utf8)
        #expect(text.contains("\"pinned_by\""))
        #expect(await s.core.pinsList().map(\.folder) == [s.project])
    }

    /// Agents pinned with their own tools until #640. What they pinned stays, under their
    /// names, and the person unpins it as any other.
    @Test func pinsAgentsMadeBeforeStayUnderTheirNames() async throws {
        let s = try await setUp(["Lead"])
        let lead = try #require(s.ids["Lead"])
        try write(s.project, "a.md")
        try write(s.project, "report.html", "<p>r</p>")
        try writePinsFile(s, PinsFile(pins: [PinEntry(path: "a.md", pinnedBy: .agent(lead)),
                                             PinEntry(path: "report.html", pinnedBy: .workflow("nightly"))],
                                      sessions: [SessionPinEntry(session: lead, pinnedBy: .agent(lead))]))
        let views = await s.core.pinViews(s.project)
        #expect(views.map(\.pinnedBy.kind) == [.agent, .workflow])
        #expect(views.map(\.pinnedBy.name) == ["Lead", "nightly"])
        #expect(await s.core.pinsList().first?.sessions == [lead])

        try await unpin(s, "a.md")
        try await unpin(s, "report.html")
        try await s.core.unpinSessionByPerson(DaemonAPI.PinSessionRequest(folder: s.project, agentID: lead))
        // The last one gone takes the file with it.
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func titlesDefaultToTheFileOrItsFolder() {
        #expect(PinRules.defaultTitle("docs/roadmap.md") == "roadmap")
        #expect(PinRules.defaultTitle("coverage/index.html") == "coverage")
        #expect(PinRules.defaultTitle("specs/159-pinned-pages/README.md") == "159-pinned-pages")
        #expect(PinRules.defaultTitle("README.md") == "README")
        #expect(PinRules.normalize("./docs//a.md") == "docs/a.md")
        #expect(PinRules.normalize("../a.md") == nil)
        #expect(PinRules.normalize("/etc/a.md") == nil)
    }

    @Test func onlyMarkdownAndHTMLInTheProjectArePinned() async throws {
        let s = try await setUp([])
        try write(s.project, "notes.txt")
        let txt = await refusal { try await pin(s, "notes.txt") }
        #expect(txt?.contains("only a Markdown (.md) or HTML (.html) page") == true)
        let gone = await refusal { try await pin(s, "nowhere.md") }
        #expect(gone?.contains("there is no file at nowhere.md") == true)
        let outside = await refusal { try await pin(s, "/etc/hosts.md") }
        #expect(outside?.contains("is not in this project") == true)
        let stranger = await refusal {
            try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: URL(filePath: "/etc"), path: "hosts.md"))
        }
        #expect(stranger?.contains("no project at") == true)
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func theLimitIsTenAndSaysSo() async throws {
        let s = try await setUp([])
        for index in 1...PinLimits.perProject {
            try write(s.project, "p\(index).md")
            try await pin(s, "p\(index).md")
        }
        try write(s.project, "eleven.md")
        let message = await refusal { try await pin(s, "eleven.md") }
        #expect(message == "Nothing was pinned: this project already has 10 pins, pages and views together, "
            + "the most it can have. Unpin one first.")
        // Pinning one already pinned is a retitle, not a new pin.
        let again = try await pin(s, "p3.md", title: "Three")
        #expect(again.map(\.title).dropFirst(2).first == "Three")
        #expect(try pinsFile(s).pins.count == 10)
    }

    @Test func thePersonUnpinsAnyPinByItsPath() async throws {
        let s = try await setUp([])
        try write(s.project, "a.md")
        try write(s.project, "b.html", "<p>b</p>")
        try await pin(s, "a.md")
        try await pin(s, s.project.appending(path: "b.html").path)
        #expect(try pinsFile(s).pins.map(\.path) == ["a.md", "b.html"])
        let never = await refusal { try await unpin(s, "c.md") }
        #expect(never == "Nothing was unpinned: c.md is not pinned in this project.")
        try await unpin(s, s.project.appending(path: "a.md").path)
        try await unpin(s, "b.html")
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func pinsMoveByDrop() async throws {
        let s = try await setUp([])
        for name in ["a", "b", "c"] {
            try write(s.project, "\(name).md")
            try await pin(s, "\(name).md")
        }
        // A drop names the whole order; anything it leaves out keeps its place after.
        try await arrange(s, ["b.md", "gone.md", "a.md"])
        #expect(try pinsFile(s).pins.map(\.path) == ["b.md", "a.md", "c.md"])
        try await arrange(s, ["c.md"])
        #expect(try pinsFile(s).pins.map(\.path) == ["c.md", "b.md", "a.md"])
    }

    @Test func aDeletedFileStaysPinnedAndMissing() async throws {
        let s = try await setUp([])
        try write(s.project, "a.md")
        try await pin(s, "a.md")
        try FileManager.default.removeItem(at: s.project.appending(path: "a.md"))
        #expect(await s.core.pinViews(s.project).map(\.missing) == [true])
        try write(s.project, "a.md")
        #expect(await s.core.pinViews(s.project).map(\.missing) == [false])
    }

    @Test func pagesAreReadAndWrittenOnlyInsideTheProject() async throws {
        let s = try await setUp([])
        try write(s.project, "docs/a.md", "hello\n")
        let reading = try await s.core.readPage(DaemonAPI.PinReadRequest(folder: s.project, path: "docs/a.md"))
        guard case .text(let text, _, _, _) = reading else { Issue.record("not text"); return }
        #expect(text == "hello\n")
        let climb = await refusal { try await s.core.readPage(DaemonAPI.PinReadRequest(folder: s.project, path: "../x.md")) }
        #expect(climb?.contains("is not in this project") == true)
        // A link inside the folder that points out of it is refused, not followed.
        try FileManager.default.createSymbolicLink(at: s.project.appending(path: "out.md"),
                                                   withDestinationURL: URL(filePath: "/etc/hosts"))
        let linked = await refusal { try await s.core.readPage(DaemonAPI.PinReadRequest(folder: s.project, path: "out.md")) }
        #expect(linked?.contains("is not in this project") == true)
        let stranger = await refusal {
            try await s.core.readPage(DaemonAPI.PinReadRequest(folder: URL(filePath: "/etc"), path: "hosts"))
        }
        #expect(stranger?.contains("no project at") == true)
        try await s.core.writePage(DaemonAPI.PinWriteRequest(folder: s.project, path: "docs/a.md", text: "typed\n"))
        #expect(try String(contentsOf: s.project.appending(path: "docs/a.md"), encoding: .utf8) == "typed\n")
        let html = await refusal {
            try await s.core.writePage(DaemonAPI.PinWriteRequest(folder: s.project, path: "docs/b.html", text: "x"))
        }
        #expect(html?.contains("Only a Markdown page") == true)
    }

    @Test func aBadFileIsReadForWhatItCanUse() throws {
        let json = """
            {"pins": [{"path": "a.md", "pinned_by": {"person": true}},
                      {"path": "a.md", "pinned_by": {"person": true}},
                      {"path": "../x.md", "pinned_by": {"person": true}},
                      {"path": "x.txt", "pinned_by": {"person": true}}]}
            """
        let read = try PinsFile.read(Data(json.utf8))
        #expect(read.file.pins.map(\.path) == ["a.md"])
        #expect(read.skipped == 3)
    }

    // MARK: A pins file that does not read (#205)

    /// Conflict markers, a newer build's pinner, and a file that may not be read: no pin
    /// change writes over it, it is never moved inside the project, a copy is kept under
    /// the daemon's root, and once it reads again pins change as before.
    @Test(arguments: ["conflict", "permissions"])
    func aPinsFileThatDoesNotReadIsNeverWrittenOver(_ how: String) async throws {
        let s = try await setUp([])
        try write(s.project, "docs/a.md")
        try write(s.project, "docs/b.md")
        try await pin(s, "docs/a.md")
        let url = s.project.appending(path: PinsFile.path)
        let good = try Data(contentsOf: url)
        let bytes: Data = switch how {
        case "conflict": Data("<<<<<<< HEAD\n".utf8) + good + Data("=======\n{\"pins\":[]}\n>>>>>>> b\n".utf8)
        case "newer": Data(#"{"pins":[{"path":"docs/a.md","pinned_by":{"team":{"id":"x"}}}]}"#.utf8)
        default: good
        }
        try bytes.write(to: url)
        if how == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }

        #expect(await s.core.pinViews(s.project).isEmpty)
        let refused = await refusal { try await pin(s, "docs/b.md") }
        #expect(refused?.contains("could not be read") == true, "\(refused ?? "nil")")
        #expect(await refusal { try await s.core.arrangePins(DaemonAPI.PinArrangeRequest(folder: s.project, paths: [])) } != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == bytes, "byte for byte")
        let beside = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!beside.contains { $0.contains(".corrupt-") }, "nothing set aside inside the project: \(beside)")
        if how != "permissions" {
            let kept = StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root))
            #expect(kept.count == 1)
            #expect(try kept.first.map { try Data(contentsOf: $0) } == bytes)

            // Fixed by hand: pins change again.
            try good.write(to: url)
            try await pin(s, "docs/b.md")
            #expect(try pinsFile(s).pins.map(\.path) == ["docs/a.md", "docs/b.md"])
        }
    }

    /// A newer build's pins (a kind of page or a pinner this build does not know) read as
    /// far as they can; before a change drops them, the whole file is kept under the root.
    @Test func aNewerBuildsPinsAreKeptBeforeAChangeDropsThem() async throws {
        let s = try await setUp([])
        try write(s.project, "docs/a.md")
        try write(s.project, "docs/b.md")
        let url = s.project.appending(path: PinsFile.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"pins":[{"path":"docs/a.md","pinned_by":{"team":"x"}},{"path":"docs/c.pdf","pinned_by":{"person":true}}]}"#.utf8)
        try newer.write(to: url)

        try await pin(s, "docs/b.md")
        let kept = StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root))
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == newer, "byte for byte")
        try await pin(s, "docs/a.md", title: "A")
        #expect(StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root)).count == 1,
                "kept once")
    }

    // MARK: Pinned sessions (#180)

    @Test func sessionsArePinnedBesideThePagesInTheSameFile() async throws {
        let s = try await setUp(["Lead", "Intake", "Helper"])
        let (lead, intake, helper) = (try #require(s.ids["Lead"]), try #require(s.ids["Intake"]), try #require(s.ids["Helper"]))
        try write(s.project, "a.md")
        try await pin(s, "a.md")
        let pagesOnly = try Data(contentsOf: s.project.appending(path: PinsFile.path))
        #expect(!String(decoding: pagesOnly, as: UTF8.self).contains("sessions"), "a file of pages is as it was")

        for id in [helper, lead, intake, lead] { try await pinSession(s, id) }
        #expect(try pinsFile(s).sessionPins.map(\.session) == [helper, lead, intake], "each once")
        #expect(try pinsFile(s).pins.map(\.path) == ["a.md"], "the pages are untouched")
        #expect(try pinsFile(s).sessionPins.allSatisfy { $0.pinnedBy == .thePerson })

        let listed = await s.core.pinsList()
        #expect(listed.first?.sessions == [helper, lead, intake])

        try await s.core.arrangeSessionPins(DaemonAPI.PinArrangeSessionsRequest(
            folder: s.project, agentIDs: [intake, UUID(), lead]))
        #expect(try pinsFile(s).sessionPins.map(\.session) == [intake, lead, helper])

        for id in [intake, lead, helper] {
            try await s.core.unpinSessionByPerson(DaemonAPI.PinSessionRequest(folder: s.project, agentID: id))
        }
        try await unpin(s, "a.md")
        // Nothing pinned at all takes the file with it.
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func archivingUnpinsAndBringingBackDoesNotPinAgain() async throws {
        let s = try await setUp(["Lead", "Intake"])
        let (lead, intake) = (try #require(s.ids["Lead"]), try #require(s.ids["Intake"]))
        try await pinSession(s, lead)
        try await pinSession(s, intake)
        try await s.core.archive(lead)
        #expect(try pinsFile(s).sessionPins.map(\.session) == [intake])
        let archived = await refusal { try await pinSession(s, lead) }
        #expect(archived == "Nothing was pinned: an archived session can't be pinned.")
        try await s.core.unarchive(lead)
        #expect(try pinsFile(s).sessionPins.map(\.session) == [intake])
    }

    @Test func aSessionFromElsewhereIsRefusedAndTheLimitIsTen() async throws {
        let names = (1...11).map { "Session \($0)" }  // index-ok: eleven
        let s = try await setUp(names)
        let elsewhere = await refusal { try await pinSession(s, UUID()) }
        #expect(elsewhere == "Nothing was pinned: that session is not in this project.")
        for name in names.prefix(10) { try await pinSession(s, s.ids[name]!) }
        let full = await refusal { try await pinSession(s, s.ids[names[10]]!) }
        #expect(full == "Nothing was pinned: this project already has 10 pinned sessions, the most it can have. "
            + "Unpin one first.")
    }

    @Test func aSessionPinReadBackKeepsEachOnceAndUnderTheLimit() throws {
        let one = UUID()
        let raw = PinsFile(pins: [], sessions: [SessionPinEntry(session: one, pinnedBy: .thePerson),
                                                SessionPinEntry(session: one, pinnedBy: .thePerson)]
            + (0..<12).map { _ in SessionPinEntry(session: UUID(), pinnedBy: .thePerson) })
        let read = try PinsFile.read(raw.fileData())
        #expect(read.file.sessionPins.count == PinLimits.sessionsPerProject)
        #expect(read.file.sessionPins.first?.session == one)
        #expect(read.skipped == 4)
    }

    // MARK: Pinned workflows (#432)

    private func writeWorkflow(_ s: Setup, _ id: String) throws {
        try write(s.project, ".agents/workflows/\(id).md", "---\non: manual\n---\n\nGo.\n")
    }

    private func pinFlow(_ s: Setup, _ id: String) async throws {
        try await s.core.pinWorkflowByPerson(DaemonAPI.WorkflowRequest(folder: s.project, workflowID: id))
    }

    @Test func workflowsArePinnedBesideTheSessionsInTheSameFile() async throws {
        let s = try await setUp(["Lead"])
        for id in ["release-notes", "triage", "tidy"] { try writeWorkflow(s, id) }
        await s.core.rescanWorkflows(in: s.project)
        try await pinSession(s, s.ids["Lead"]!)
        let sessionsOnly = try Data(contentsOf: s.project.appending(path: PinsFile.path))
        #expect(!String(decoding: sessionsOnly, as: UTF8.self).contains("workflows"), "a file without them is as it was")

        try await pinFlow(s, "release-notes")
        try await pinFlow(s, "triage")
        try await pinFlow(s, "release-notes")
        #expect(try pinsFile(s).workflowPins.map(\.workflow) == ["release-notes", "triage"])
        #expect(try pinsFile(s).workflowPins.first?.pinnedBy == .thePerson)
        #expect(try pinsFile(s).sessionPins.count == 1, "the sessions are untouched")
        #expect(await s.core.pinsList().first?.workflows == ["release-notes", "triage"])

        try await s.core.arrangeWorkflowPins(DaemonAPI.PinArrangeWorkflowsRequest(
            folder: s.project, workflowIDs: ["triage", "gone", "release-notes"]))
        #expect(try pinsFile(s).workflowPins.map(\.workflow) == ["triage", "release-notes"])

        try await s.core.unpinWorkflowByPerson(DaemonAPI.WorkflowRequest(folder: s.project, workflowID: "triage"))
        #expect(try pinsFile(s).workflowPins.map(\.workflow) == ["release-notes"])
        let missing = await refusal { try await pinFlow(s, "nothing-here") }
        #expect(missing == "Nothing was pinned: there is no workflow called nothing-here in this project.")
    }

    @Test func archivingAWorkflowUnpinsItAndBringingItBackDoesNotPinAgain() async throws {
        let s = try await setUp([])
        try writeWorkflow(s, "release-notes")
        try writeWorkflow(s, "triage")
        await s.core.rescanWorkflows(in: s.project)
        try await pinFlow(s, "release-notes")
        try await pinFlow(s, "triage")
        _ = try await s.core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: s.project, workflowID: "release-notes", archived: true))
        #expect(try pinsFile(s).workflowPins.map(\.workflow) == ["triage"])
        let archived = await refusal { try await pinFlow(s, "release-notes") }
        #expect(archived == "Nothing was pinned: an archived workflow can't be pinned.")
        _ = try await s.core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: s.project, workflowID: "release-notes", archived: false))
        #expect(try pinsFile(s).workflowPins.map(\.workflow) == ["triage"])
    }

    @Test func aWorkflowPinReadBackKeepsEachOnceAndUnderTheLimit() throws {
        let raw = PinsFile(workflows: [WorkflowPinEntry(workflow: "a", pinnedBy: .thePerson),
                                       WorkflowPinEntry(workflow: "a", pinnedBy: .thePerson)]
            + (0..<12).map { WorkflowPinEntry(workflow: "w\($0)", pinnedBy: .thePerson) })
        let read = try PinsFile.read(raw.fileData())
        #expect(read.file.workflowPins.count == PinLimits.workflowsPerProject)
        #expect(read.file.workflowPins.first?.workflow == "a")
        #expect(read.skipped == 4)
    }

    // MARK: Views (#189)

    private let testView = ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "show_test_view",
                                   arguments: ["note": "pinned"])

    private func pinView(_ s: Setup, _ view: ViewPin, title: String? = nil) async throws {
        _ = try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: s.project, view: view, title: title))
    }

    @Test func thePersonPinsAViewWithItsFeedingCall() async throws {
        let s = try await setUp([])
        await s.core.offerTestView(true)
        try await pinView(s, testView, title: "Test view")
        let entry = try #require(try pinsFile(s).pins.first)
        #expect(entry.view == testView)
        #expect(entry.pinnedBy == .thePerson)
        // The file says `view`, never a `path`, for a view pin.
        let raw = try String(contentsOf: s.project.appending(path: PinsFile.path), encoding: .utf8)
        #expect(raw.contains("\"view\"") && !raw.contains("\"path\""))
        let shown = try #require(await s.core.pinViews(s.project).first)
        #expect(shown.kind == .view && !shown.missing && shown.missingReason == nil)
        #expect(shown.path == "ui://agents/test-view" && shown.title == "Test view")
        // Pinned again: the new arguments, still one pin.
        try await pinView(s, ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "show_test_view",
                                     arguments: ["note": "again"]))
        #expect(try pinsFile(s).pins.count == 1)
        #expect(try pinsFile(s).pins.first?.view?.arguments?["note"]?.stringValue == "again")
        // Moved and unpinned by its address.
        try write(s.project, "a.md")
        try await pin(s, "a.md")
        try await arrange(s, ["a.md", "ui://agents/test-view"])
        #expect(try pinsFile(s).pins.map(\.path) == ["a.md", "ui://agents/test-view"])
        try await unpin(s, "ui://agents/test-view")
        #expect(try pinsFile(s).pins.map(\.path) == ["a.md"])
    }

    @Test func onlyAReadOnlyToolOfASetUpServerFeedsAPin() async throws {
        let s = try await setUp([])
        await s.core.offerTestView(true)
        func refused(_ view: ViewPin) async -> String? { await refusal { try await pinView(s, view) } }
        let counting = await refused(ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "test_view_count"))
        #expect(counting?.contains("test_view_count can't feed a pin") == true)
        let gone = await refused(ViewPin(server: "agents", uri: "ui://agents/dashboard", tool: "read_dashboard"))
        #expect(gone == "Nothing was pinned: the agents server has no view at ui://agents/dashboard.")
        let other = await refused(ViewPin(server: "github", uri: "ui://github/issues", tool: "list_issues"))
        // Another server's view can be pinned (#191), once it is set up here.
        #expect(other?.contains("github is not set up here") == true)
        let big = await refused(ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "show_test_view",
                                        arguments: ["note": .string(String(repeating: "x", count: 3000))]))
        #expect(big?.contains("at most 2 KB") == true)
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func theLimitCountsPagesAndViewsTogether() async throws {
        let s = try await setUp([])
        await s.core.offerTestView(true)
        for index in 0..<9 {
            try write(s.project, "p\(index).md")
            try await pin(s, "p\(index).md")
        }
        try await pinView(s, ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "show_test_view"))
        try write(s.project, "eleven.md")
        let message = await refusal { try await pin(s, "eleven.md") }
        #expect(message?.contains("already has 10 pins, pages and views together") == true)
        // The person unpins the view by its address.
        try await unpin(s, "ui://agents/test-view")
        #expect(try pinsFile(s).pins.count == 9)
    }

    @Test func aViewThisHostCannotDrawShowsAsMissingWithWhy() async throws {
        let s = try await setUp([])
        try writePinsFile(s, PinsFile(pins: [
            PinEntry(view: ViewPin(server: "github", uri: "ui://github/issues", tool: "list_issues"), pinnedBy: .thePerson),
            PinEntry(view: ViewPin(server: "agents", uri: "ui://agents/test-view", tool: "show_test_view"), pinnedBy: .thePerson),
        ]))
        // The test view is not offered on this host.
        let shown = await s.core.pinViews(s.project)
        #expect(shown.map(\.missingReason) == [PinMissing.serverNotSetUp, PinMissing.noSuchView])
        #expect(shown.allSatisfy { $0.missing })
        #expect(shown.first?.title == "Issues")
        await s.core.offerTestView(true)
        #expect(await s.core.pinViews(s.project).map(\.missing) == [true, false])
    }

    @Test func anEntryThisBuildCannotReadIsKeptAndCounted() async throws {
        let s = try await setUp([])
        try write(s.project, "a.md")
        let raw = #"{"pins":[{"path":"a.md","pinned_by":{"person":true}},{"widget":{"kind":"later"},"pinned_by":{"person":true}}]}"#
        try FileManager.default.createDirectory(at: s.project.appending(path: ".agents"), withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: s.project.appending(path: PinsFile.path))
        #expect(await s.core.pinViews(s.project).map(\.path) == ["a.md"])
        try write(s.project, "b.md")
        try await pin(s, "b.md")
        let file = try pinsFile(s)
        #expect(file.pins.map(\.path) == ["a.md", "b.md"])
        #expect(file.unread.count == 1 && file.pinCount == 3)
        #expect(file.unread.first?["widget"]?["kind"]?.stringValue == "later")
    }

    @Test func aPinnedViewIsFedOnlyByAReadOnlyTool() async throws {
        let s = try await setUp([])
        await s.core.offerTestView(true)
        func feed(_ name: String) async throws -> JSONValue {
            try await s.core.callFromView(DaemonAPI.ViewCallRequest(
                agentID: UUID(), viewID: UUID(), name: name, arguments: ["note": "pinned"], project: s.project, feed: true))
        }
        guard AppViewCatalog.offersTestView else {
            // The catalog's own tools are read from the daemon's environment.
            let refused = await refusal { try await feed("test_view_count") }
            #expect(refused?.contains("may not call test_view_count") == true)
            return
        }
        let fed = try await feed("show_test_view")
        #expect(fed["structuredContent"]?["note"]?.stringValue == "pinned")
        let refused = await refusal { try await feed("test_view_count") }
        #expect(refused?.contains("can't feed a pinned view") == true)
    }
}

