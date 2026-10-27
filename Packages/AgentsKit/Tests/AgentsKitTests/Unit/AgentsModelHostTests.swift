import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One window, several daemons (037): what each sent is filed under where it came from.
@MainActor
@Suite("The model across hosts")
struct AgentsModelHostTests {
    private let devbox = MachineRef(rawValue: "devbox01")
    private let gpu = MachineRef(rawValue: "gpu00001")
    private let path = URL(filePath: "/home/alex/src/api")

    private func agent(_ cwd: URL, title: String = "t") -> Agent {
        Agent(runtimeID: "claude", cwd: cwd, title: title, state: .finished, endedReason: .endTurn)
    }

    private func summary(_ folder: URL) -> DaemonAPI.FolderSummary {
        DaemonAPI.FolderSummary(folder: Folder(folder: folder), name: folder.lastPathComponent, exists: true,
                                 lastActivityAt: Date(), counts: [:])
    }

    @Test func whatANotificationCarriesIsFiledUnderItsHost() throws {
        let model = AgentsModel()
        let one = agent(path)
        model.apply(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(one), from: devbox)
        model.apply(DaemonAPI.Notification.folderChanged, try JSONValue.encoding(summary(path)), from: devbox)
        #expect(model.agent(one.id)?.host == devbox)
        #expect(model.folder(FolderKey(host: devbox, folder: path)) != nil)
        #expect(model.folder(FolderKey(host: .mac, folder: path)) == nil)
    }

    /// A folder added brings workflows no notification carries, so the client lists them (#1798).
    @Test func aFolderNotHeldYetIsAnAddition() {
        let model = AgentsModel()
        let added = AgentsModel.Update.folderChanged(summary(path))
        #expect(model.addsFolder(added))
        #expect(model.addsFolder(added, from: devbox))
        model.apply(added, from: devbox)
        #expect(!model.addsFolder(added, from: devbox), "a change to a held folder is not an addition")
        #expect(model.addsFolder(added), "the same folder on the Mac is another folder")
        #expect(!model.addsFolder(.folderRemoved(FolderKey(host: .mac, folder: path))))
    }

    @Test func aHostIsNeverWrittenIntoTheRecord() throws {
        var one = agent(path)
        one.host = devbox
        var folder = summary(path)
        folder.host = devbox
        let agentJSON = String(decoding: try JSONEncoder().encode(one), as: UTF8.self)
        let folderJSON = String(decoding: try JSONEncoder().encode(folder), as: UTF8.self)
        #expect(!agentJSON.contains("devbox01"))
        #expect(!folderJSON.contains("devbox01"))
        #expect(try JSONDecoder().decode(Agent.self, from: Data(agentJSON.utf8)).host == .mac)
        #expect(try JSONDecoder().decode(DaemonAPI.FolderSummary.self, from: Data(folderJSON.utf8)).host == .mac)
    }

    @Test func aHostReListingReplacesOnlyItsOwn() {
        let model = AgentsModel()
        let mine = agent(URL(filePath: "/Users/alex/app"))
        let theirs = agent(path)
        model.replaceAgents([mine], from: .mac)
        model.replaceFolders([summary(URL(filePath: "/Users/alex/app"))], from: .mac)
        model.replaceAgents([theirs], from: devbox)
        model.replaceFolders([summary(path)], from: devbox)
        #expect(model.agents.count == 2)
        #expect(model.folders.count == 2)

        model.replaceAgents([], from: devbox)
        model.replaceFolders([], from: devbox)
        #expect(model.agents.map(\.id) == [mine.id], "the Mac's are untouched by a server re-listing")
        #expect(model.folders.count == 1)
    }

    @Test func theSamePathOnTwoHostsIsTwoFoldersWithTheirOwnAgents() {
        let model = AgentsModel()
        let a = agent(path, title: "on devbox")
        let b = agent(path, title: "on gpu")
        model.replaceFolders([summary(path)], from: devbox)
        model.replaceFolders([summary(path)], from: gpu)
        model.replaceAgents([a], from: devbox)
        model.replaceAgents([b], from: gpu)
        #expect(model.folders.count == 2)
        let onDevbox = FolderKey(host: devbox, folder: path)
        #expect(model.agents(in: onDevbox, group: .finished).map(\.id) == [a.id])
        #expect(model.counts(in: onDevbox)[.finished] == 1)
        #expect(model.counts(in: FolderKey(host: gpu, folder: path))[.finished] == 1)
    }

    @Test func aFolderChangeUpdatesOnlyItsHostsCopy() throws {
        let model = AgentsModel()
        model.replaceFolders([summary(path)], from: devbox)
        model.replaceFolders([summary(path)], from: gpu)
        var renamed = summary(path)
        renamed.name = "renamed"
        model.apply(DaemonAPI.Notification.folderChanged, try JSONValue.encoding(renamed), from: gpu)
        #expect(model.folder(FolderKey(host: gpu, folder: path))?.name == "renamed")
        #expect(model.folder(FolderKey(host: devbox, folder: path))?.name == "api")
    }

    @Test func withoutAHostEverythingIsTheMacs() throws {
        let model = AgentsModel()
        let one = agent(path)
        model.apply(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(one))
        model.replaceFolders([summary(path)])
        #expect(model.agent(one.id)?.host == .mac)
        #expect(model.folder(FolderKey(folder: path)) != nil)
        #expect(model.folder(path) != nil, "the phone's calls read as they always did")
    }

    /// A lean list (#107) does not empty the open chat's menus, read whole a moment before.
    @Test func aLeanListKeepsTheListsHeldAndANotificationReplacesThem() throws {
        let model = AgentsModel()
        var whole = agent(path)
        whole.availableCommands = [SlashCommand(name: "review", description: "Review")]
        whole.advertisedOptions = [ConfigOption(id: "model", name: "Model", type: "select")]
        model.takeListed([whole])

        var renamed = whole.leaned()
        renamed.title = "renamed"
        model.replaceAgents([renamed], from: .mac)
        #expect(model.agent(whole.id)?.title == "renamed")
        #expect(model.agent(whole.id)?.availableCommands.map(\.name) == ["review"])
        #expect(model.agent(whole.id)?.advertisedOptions.map(\.id) == ["model"])

        var changed = whole
        changed.availableCommands = [SlashCommand(name: "compact", description: "Compact")]
        model.apply(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(changed), from: .mac)
        #expect(model.agent(whole.id)?.availableCommands.map(\.name) == ["compact"])

        // One never held whole stays lean: nothing is made up for it.
        let stranger = agent(path, title: "other").leaned()
        model.takeListed([stranger])
        #expect(model.agent(stranger.id)?.availableCommands.isEmpty == true)
    }
}
