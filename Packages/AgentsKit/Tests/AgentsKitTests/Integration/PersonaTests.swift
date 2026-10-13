import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Personas (#760): a kind of session picked when an agent starts, from
/// `.agents/personas/` in the project or in `~/.agents`.
@Suite("Personas", .timeLimit(.minutes(1)))
struct PersonaTests {
    private func folders() throws -> (root: URL, work: URL, home: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPersonaTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [work, home] {
            try FileManager.default.createDirectory(at: Persona.folder(in: folder), withIntermediateDirectories: true)
        }
        return (root, work, home)
    }

    private func write(_ text: String, _ id: String, in base: URL) throws {
        try text.write(to: Persona.folder(in: base).appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }

    private let reviewer = """
        ---
        name: Reviewer
        description: Reads a change and says what is wrong with it.
        runtime: codex
        model: sonnet
        permission-mode: plan
        labels: [review]
        options:
          fast: true
        ---

        You review changes. Use the code-review skill.
        """

    @Test func theFrontMatterIsReadAsAWorkflowsIsAndTheBodyIsThePrompt() {
        let (persona, prompt) = PersonaFile.parse(reviewer, id: "reviewer", origin: .project)
        #expect(persona.problem == nil)
        #expect(persona.name == "Reviewer")
        #expect(persona.description == "Reads a change and says what is wrong with it.")
        #expect(persona.settings == WorkflowSettings(permissionMode: "plan", runtimeID: "codex", model: "sonnet",
                                                     options: ["fast": "true"], labels: ["review"]))
        #expect(prompt == "You review changes. Use the code-review skill.")
    }

    @Test func aFileWithNoFrontMatterIsAllPromptAndNamedByItsFile() {
        let (persona, prompt) = PersonaFile.parse("Be terse.\n", id: "terse", origin: .personal)
        #expect(persona.name == "terse")
        #expect(persona.problem == nil)
        #expect(prompt == "Be terse.")
    }

    @Test func aBrokenFileIsListedWithWhyAndNeverFound() throws {
        let (_, work, home) = try folders()
        try write("---\nname: Broken\nlabels:\n  nested: no\n---\nHi", "broken", in: work)
        let listed = PersonaFile.list(project: work, home: home)
        #expect(listed.map(\.id) == ["broken"])
        #expect(listed.first?.problem != nil)
        #expect(PersonaFile.find("broken", project: work, home: home) == nil)
    }

    @Test func theProjectsPersonaWinsOverTheHomesOfTheSameName() throws {
        let (_, work, home) = try folders()
        try write("---\nname: Mine\n---\nhome", "writer", in: home)
        try write("---\nname: Project's\n---\nproject", "writer", in: work)
        try write("---\nname: Alpha\n---\nalpha", "alpha", in: home)

        let listed = PersonaFile.list(project: work, home: home)
        #expect(listed.map(\.name) == ["Alpha", "Project's"])
        #expect(listed.map(\.origin) == [.personal, .project])
        #expect(PersonaFile.find("writer", project: work, home: home)?.prompt == "project")
        #expect(PersonaFile.find("alpha", project: work, home: home)?.prompt == "alpha")
        #expect(PersonaFile.find("../work/.agents/personas/writer", project: work, home: home) == nil)
    }

    @Test func choicesAreWhatTheRuntimeOffersEachKeyOnItsOwn() {
        func choices(_ values: String...) -> [ConfigChoice] {
            values.map { ConfigChoice(value: .string($0), name: $0) }
        }
        let advertised = [
            ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                         currentValue: .string("default"), options: choices("default", "plan")),
            ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                         currentValue: .string("opus"), options: choices("opus", "haiku")),
            ConfigOption(id: "fast", name: "Fast", type: "boolean", currentValue: .bool(false)),
        ]
        let persona = PersonaFile.parse(reviewer, id: "reviewer", origin: .project).persona
        // sonnet is not offered, so the model stays as the form has it; the rest apply.
        #expect(persona.choices(against: advertised) == ["mode": .string("plan"), "fast": .bool(true)])
    }

    @Test func aStartAsAPersonaSendsItsPromptWithTheBriefingAndRecordsOnlyTheWords() async throws {
        let (root, work, home) = try folders()
        try write(reviewer, "reviewer", in: work)
        var locations = StoreLocations(root: root.appending(path: "store"))
        locations.personalHome = home
        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "look at main",
                                            persona: "reviewer"))
        await eventually("the first prompt was sent") {
            await launcher.allAgents.first?.promptContent != nil
        }

        let sent = (await launcher.allAgents.first?.promptContent?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        #expect(sent == [Briefing.asSent(to: "cursor"), "You review changes. Use the code-review skill.", "look at main"])
        #expect(await core.agent(id)?.persona == "reviewer")
    }

    @Test func aPersonaThatIsNotThereStartsTheAgentWithoutOne() async throws {
        let (root, work, home) = try folders()
        var locations = StoreLocations(root: root.appending(path: "store"))
        locations.personalHome = home
        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go", persona: "gone"))
        #expect(await core.agent(id)?.persona == nil)
    }

    /// This project's own (#909): both read, each with a description, a runtime, labels and a
    /// prompt.
    @Test func thisProjectsPersonasAreReadWithNothingWrong() {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let listed = PersonaFile.list(project: repo, home: nil)
        #expect(listed.map(\.name) == ["Product Owner", "Scrum Master"])
        for persona in listed {
            #expect(persona.problem == nil)
            #expect(persona.description?.isEmpty == false)
            #expect(persona.settings.runtimeID == "claude")
            #expect(!persona.settings.labels.isEmpty)
            #expect(PersonaFile.find(persona.id, project: repo, home: nil)?.prompt.isEmpty == false)
        }
    }
}
