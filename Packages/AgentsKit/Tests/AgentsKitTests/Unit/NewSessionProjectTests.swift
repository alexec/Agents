import AgentsKitCore
import Foundation
import Testing

/// New Session picks the project, then the machine (#3279).
@Suite("New Session's project")
struct NewSessionProjectTests {
    let devbox = MachineRef(rawValue: "devbox")

    private func folder(_ path: String, on host: MachineRef = .mac, project: String?) -> DaemonAPI.FolderSummary {
        var summary = DaemonAPI.FolderSummary(folder: Folder(folder: URL(filePath: path)), name: URL(filePath: path).lastPathComponent,
                                              exists: true, lastActivityAt: Date(), counts: [:])
        summary.host = host
        summary.project = project
        return summary
    }

    /// Clones on two machines are one project; a folder that names none is its own.
    @Test func foldersOfOneProjectAreOneChoice() throws {
        let agents = folder("/src/Agents", project: "p1")
        let www = folder("/src/www", project: nil)
        let clone = folder("/home/alex/Agents", on: devbox, project: "p1")
        let other = folder("/src/other", project: nil)
        let choices = NewSessionProject.choices([agents, www, clone, other])
        try #require(choices.map(\.name) == ["Agents", "www", "other"])
        #expect(choices[0].folders == [agents.key, clone.key])
        #expect(!choices[0].hidesMachine)
        #expect(choices[1].hidesMachine)
        #expect(NewSessionProject.choice(of: clone.key, in: choices)?.id == "p1")
    }

    /// This machine's folder first, then the one last used in the project, then the first.
    @Test func aPickedProjectStartsHereThenWhereLastUsed() throws {
        let mac = folder("/src/Agents", project: "p1")
        let clone = folder("/home/alex/Agents", on: devbox, project: "p1")
        let cloud = folder("/work/Agents", on: MachineRef(rawValue: "cloud-1"), project: "p1")
        let choice = try #require(NewSessionProject.choices([clone, mac, cloud]).first)
        #expect(NewSessionProject.folder(in: choice, isHere: { $0 == .mac }, remembered: cloud.key) == mac.key)
        #expect(NewSessionProject.folder(in: choice, isHere: { _ in false }, remembered: cloud.key) == cloud.key)
        #expect(NewSessionProject.folder(in: choice, isHere: { _ in false }, remembered: nil) == clone.key)
    }
}
