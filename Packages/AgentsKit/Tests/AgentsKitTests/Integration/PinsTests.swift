import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Pinned pages (#159), through the daemon: agents pinning with `pin_page`, the person's
/// Pin, Unpin and drag, the one file in the project folder, the limit, and the pages read
/// for a screen. Agents are written to disk before the daemon reads it, so no runtime is
/// involved.
@Suite("Pinned pages", .timeLimit(.minutes(1)))
struct PinsTests {
    private struct Setup {
        var core: DaemonCore
        var project: URL
        var tree: URL
        var tokens: [String: String]
        var ids: [String: UUID]
    }

    private func setUp(_ agents: [(name: String, worktree: Bool, workflow: String?)]) async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPins-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        let tree = project.appendingPathComponent(".agents/worktrees/lane", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        var ids: [String: UUID] = [:]
        for agent in agents {
            var record = Agent(runtimeID: "claude", cwd: agent.worktree ? tree : project, title: agent.name,
                               state: .finished, endedReason: .endTurn, startedByWorkflow: agent.workflow)
            if agent.worktree {
                record.worktree = AgentWorktree(name: "lane", root: tree, branch: "agents/lane", project: project,
                                                base: "main", madeByApp: true)
            }
            try await store.save(record)
            ids[agent.name] = record.id
        }
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        var tokens: [String: String] = [:]
        for (name, id) in ids {
            let token = UUID().uuidString
            await core.bindAppToken(token, to: id)
            tokens[name] = token
        }
        return Setup(core: core, project: project, tree: tree, tokens: tokens, ids: ids)
    }

    private func write(_ folder: URL, _ path: String, _ text: String = "# Page\n") throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func unpin(_ s: Setup, _ who: String, _ arguments: JSONValue) async throws -> String {
        try await s.core.unpinPage(DaemonAPI.PinToolRequest(token: s.tokens[who]!, arguments: arguments))
    }

    private func move(_ s: Setup, _ who: String, _ arguments: JSONValue) async throws -> String {
        try await s.core.movePin(DaemonAPI.PinToolRequest(token: s.tokens[who]!, arguments: arguments))
    }

    private func pin(_ s: Setup, _ who: String, _ arguments: JSONValue) async throws -> String {
        try await s.core.pinPage(DaemonAPI.PinToolRequest(token: s.tokens[who]!, arguments: arguments))
    }

    private func refusal(_ body: () async throws -> Any) async -> String? {
        do { _ = try await body(); return nil } catch let error as JSONRPCError { return error.message } catch { return "\(error)" }
    }

    private func pinsFile(_ s: Setup) throws -> PinsFile {
        try PinsFile.read(Data(contentsOf: s.project.appending(path: PinsFile.path))).file
    }

    @Test func anAgentPinsAPageIntoTheProjectFile() async throws {
        let s = try await setUp([("Lead", false, nil)])
        try write(s.project, "docs/roadmap.md")
        let answer = try await pin(s, "Lead", ["path": "docs/roadmap.md", "title": "Roadmap"])
        #expect(answer.contains("Pinned docs/roadmap.md"))
        #expect(answer.contains("1. Roadmap — docs/roadmap.md [markdown], pinned by you"))
        let file = try pinsFile(s)
        #expect(file.pins == [PinEntry(path: "docs/roadmap.md", title: "Roadmap", pinnedBy: .agent(s.ids["Lead"]!))])
        let text = try String(contentsOf: s.project.appending(path: PinsFile.path), encoding: .utf8)
        #expect(text.contains("\"pinned_by\""))
        let views = await s.core.pinViews(s.project)
        #expect(views.map(\.title) == ["Roadmap"])
        #expect(views[0].pinnedBy.name == "Lead")
        #expect(await s.core.pinsList().map(\.folder) == [s.project])
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
        let s = try await setUp([("Lead", false, nil)])
        try write(s.project, "notes.txt")
        let txt = await refusal { try await pin(s, "Lead", ["path": "notes.txt"]) }
        #expect(txt?.contains("only a Markdown (.md) or HTML (.html) page") == true)
        let gone = await refusal { try await pin(s, "Lead", ["path": "nowhere.md"]) }
        #expect(gone?.contains("there is no file at nowhere.md") == true)
        let outside = await refusal { try await pin(s, "Lead", ["path": "/etc/hosts.md"]) }
        #expect(outside?.contains("is not in this project") == true)
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func theLimitIsTenAndSaysSo() async throws {
        let s = try await setUp([("Lead", false, nil)])
        for index in 1...PinLimits.perProject {
            try write(s.project, "p\(index).md")
            _ = try await pin(s, "Lead", ["path": .string("p\(index).md")])
        }
        try write(s.project, "eleven.md")
        let message = await refusal { try await pin(s, "Lead", ["path": "eleven.md"]) }
        #expect(message == "Nothing was pinned: this project already has 10 pinned pages, the most it can have. "
            + "Unpin one first, or ask the person which to unpin.")
        let person = await refusal {
            try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: s.project, path: "eleven.md"))
        }
        #expect(person?.contains("already has 10 pinned pages") == true)
        // Pinning one already pinned is a retitle, not a new pin.
        let again = try await pin(s, "Lead", ["path": "p3.md", "title": "Three"])
        #expect(again.contains("its title is now"))
        #expect(try pinsFile(s).pins.count == 10)
    }

    @Test func anAgentUnpinsOnlyItsOwnAndThePersonUnpinsAny() async throws {
        let s = try await setUp([("Lead", false, nil), ("Helper", false, nil)])
        try write(s.project, "a.md")
        try write(s.project, "b.html", "<p>b</p>")
        _ = try await pin(s, "Lead", ["path": "a.md"])
        _ = try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: s.project, path: s.project.appending(path: "b.html").path))
        let theirs = await refusal { try await unpin(s, "Helper", ["path": "a.md"]) }
        #expect(theirs?.contains("a.md was pinned by the agent “Lead”") == true)
        let persons = await refusal { try await unpin(s, "Lead", ["path": "b.html"]) }
        #expect(persons?.contains("pinned by the person") == true)
        let done = try await unpin(s, "Lead", ["path": "a.md"])
        #expect(done.hasPrefix("Unpinned a.md."))
        try await s.core.unpinByPerson(DaemonAPI.PinPathRequest(folder: s.project, path: "b.html"))
        // The last one gone takes the file with it.
        #expect(!FileManager.default.fileExists(atPath: s.project.appending(path: PinsFile.path).path))
    }

    @Test func pinsMoveByToolAndByDrop() async throws {
        let s = try await setUp([("Lead", false, nil), ("Helper", false, nil)])
        for name in ["a", "b", "c"] {
            try write(s.project, "\(name).md")
            _ = try await pin(s, "Lead", ["path": .string("\(name).md")])
        }
        _ = try await move(s, "Helper", ["path": "c.md", "position": "first"])
        #expect(try pinsFile(s).pins.map(\.path) == ["c.md", "a.md", "b.md"])
        _ = try await move(s, "Helper", ["path": "c.md", "after": "b.md"])
        #expect(try pinsFile(s).pins.map(\.path) == ["a.md", "b.md", "c.md"])
        let bad = await refusal { try await move(s, "Helper", ["path": "a.md", "before": "a.md"]) }
        #expect(bad == "Nothing was moved: a page can't go next to itself.")
        let two = await refusal { try await move(s, "Helper", ["path": "a.md", "position": "last", "after": "b.md"]) }
        #expect(two?.contains("give one of") == true)
        // A drop names the whole order; anything it leaves out keeps its place after.
        try await s.core.arrangePins(DaemonAPI.PinArrangeRequest(folder: s.project, paths: ["b.md", "gone.md", "a.md"]))
        #expect(try pinsFile(s).pins.map(\.path) == ["b.md", "a.md", "c.md"])
    }

    @Test func aWorktreeAgentPinsTheProjectPathAndItShowsMissingUntilItLands() async throws {
        let s = try await setUp([("Lane", true, nil)])
        try write(s.tree, "docs/review.md")
        let answer = try await pin(s, "Lane", ["path": .string(s.tree.appending(path: "docs/review.md").path)])
        #expect(answer.contains("only in your worktree so far"))
        #expect(try pinsFile(s).pins.map(\.path) == ["docs/review.md"])
        #expect(await s.core.pinViews(s.project).first?.missing == true)
        try write(s.project, "docs/review.md")
        #expect(await s.core.pinViews(s.project).first?.missing == false)
    }

    @Test func aDeletedFileStaysPinnedAndMissing() async throws {
        let s = try await setUp([("Lead", false, nil)])
        try write(s.project, "a.md")
        _ = try await pin(s, "Lead", ["path": "a.md"])
        try FileManager.default.removeItem(at: s.project.appending(path: "a.md"))
        let views = await s.core.pinViews(s.project)
        #expect(views.map(\.missing) == [true])
        let read = try await s.core.readDashboard(DaemonAPI.DashboardTokenRequest(token: s.tokens["Lead"]!))
        #expect(read.contains("missing from the project folder"))
    }

    @Test func aWorkflowsRunsShareItsPins() async throws {
        let s = try await setUp([("Run 1", false, "nightly"), ("Run 2", false, "nightly")])
        try write(s.project, "report.html", "<p>r</p>")
        _ = try await pin(s, "Run 1", ["path": "report.html"])
        #expect(try pinsFile(s).pins.first?.pinnedBy == .workflow("nightly"))
        _ = try await unpin(s, "Run 2", ["path": "report.html"])
    }

    @Test func pagesAreReadAndWrittenOnlyInsideTheProject() async throws {
        let s = try await setUp([("Lead", false, nil)])
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

    @Test func aPageTileNamesAFileAndNeverGoesStale() async throws {
        let check = TileCheck.read(["id": "roadmap", "title": "Roadmap", "type": "page", "file": "docs/roadmap.md"])
        guard case .success(let read) = check else { Issue.record("refused"); return }
        #expect(read.tile.page == TilePage(file: "docs/roadmap.md"))
        let view = TileView(id: "roadmap", tile: read.tile, keeper: KeeperView(kind: .agent, id: "", name: "", state: .active))
        #expect(!DashboardModel.isStale(view, now: Date()))
        guard case .failure(let problem) = TileCheck.read(["id": "x", "title": "X", "type": "page", "file": "a.txt"]) else {
            Issue.record("taken"); return
        }
        #expect(problem.message.contains("Markdown (.md) or HTML (.html)"))
    }

    // MARK: A pins file that does not read (#205)

    /// Conflict markers, a newer build's pinner, and a file that may not be read: no pin
    /// change writes over it, it is never moved inside the project, a copy is kept under
    /// the daemon's root, and once it reads again pins change as before.
    @Test(arguments: ["conflict", "permissions"])
    func aPinsFileThatDoesNotReadIsNeverWrittenOver(_ how: String) async throws {
        let s = try await setUp([("Lead", false, nil)])
        try write(s.project, "docs/a.md")
        try write(s.project, "docs/b.md")
        _ = try await pin(s, "Lead", ["path": "docs/a.md"])
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
        let refused = await refusal { try await pin(s, "Lead", ["path": "docs/b.md"]) }
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
            _ = try await pin(s, "Lead", ["path": "docs/b.md"])
            #expect(try pinsFile(s).pins.map(\.path) == ["docs/a.md", "docs/b.md"])
        }
    }

    /// A newer build's pins (a kind of page or a pinner this build does not know) read as
    /// far as they can; before a change drops them, the whole file is kept under the root.
    @Test func aNewerBuildsPinsAreKeptBeforeAChangeDropsThem() async throws {
        let s = try await setUp([("Lead", false, nil)])
        try write(s.project, "docs/a.md")
        try write(s.project, "docs/b.md")
        let url = s.project.appending(path: PinsFile.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"pins":[{"path":"docs/a.md","pinned_by":{"team":"x"}},{"path":"docs/c.pdf","pinned_by":{"person":true}}]}"#.utf8)
        try newer.write(to: url)

        _ = try await pin(s, "Lead", ["path": "docs/b.md"])
        let kept = StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root))
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == newer, "byte for byte")
        _ = try await pin(s, "Lead", ["path": "docs/a.md", "title": "A"])
        #expect(StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root)).count == 1,
                "kept once")
    }
}
