import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Antigravity's home is the app's own (049's D7), so its skills are linked in there and
/// never in `~/.gemini` (054, T055).
@Suite("Antigravity's skills, in the home the app gives it")
struct AntigravityLayoutTests {
    private let fileManager = FileManager.default

    private func folders() throws -> (home: URL, appHome: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AntigravityLayoutTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let home = base.appending(path: "home")
        try fileManager.createDirectory(at: home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        return (home, base.appending(path: "root/runtimes/antigravity/home"))
    }

    private func skill(_ name: String, in home: URL) throws {
        let url = home.appending(path: ".agents/skills/\(name)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n".write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func reconcile(_ home: URL, _ appHome: URL, _ record: inout PersonalDotAgents.Record,
                           installed: Set<String> = ["antigravity"]) {
        PersonalDotAgents.reconcile(home: home, installed: installed, record: &record, appHomes: ["antigravity": appHome])
    }

    @Test func aSkillIsLinkedIntoItsConfigSkillsAndNowhereInTheHome() throws {
        let (home, appHome) = try folders()
        try skill("dataviz", in: home)
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, appHome, &record)

        let link = appHome.appending(path: "config/skills/dataviz")
        let target = home.appending(path: ".agents/skills/dataviz").path
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == target)
        #expect(record.links[link.path] == target)
        #expect(!DotAgents.exists(home.appending(path: ".gemini")))
    }

    @Test func notInstalledNoLink() throws {
        let (home, appHome) = try folders()
        try skill("dataviz", in: home)
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, appHome, &record, installed: ["claude"])

        #expect(!DotAgents.exists(appHome))
    }

    @Test func aDeletedLinkStaysDeletedAndAGoneSkillTakesItsLinkWithIt() throws {
        let (home, appHome) = try folders()
        try skill("dataviz", in: home)
        try skill("review", in: home)
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, appHome, &record)

        try fileManager.removeItem(at: appHome.appending(path: "config/skills/dataviz"))
        try fileManager.removeItem(at: home.appending(path: ".agents/skills/review"))
        reconcile(home, appHome, &record)

        #expect(!DotAgents.exists(appHome.appending(path: "config/skills/dataviz")))
        #expect(!DotAgents.exists(appHome.appending(path: "config/skills/review")))
        #expect(record.links[appHome.appending(path: "config/skills/review").path] == nil)
    }

    @Test func aSecondReconcileChangesNothing() throws {
        let (home, appHome) = try folders()
        try skill("dataviz", in: home)
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, appHome, &record)
        let before = record
        let link = appHome.appending(path: "config/skills/dataviz")
        let stamp = try fileManager.attributesOfItem(atPath: link.path)[.modificationDate] as? Date

        reconcile(home, appHome, &record)

        #expect(record == before)
        #expect(try fileManager.attributesOfItem(atPath: link.path)[.modificationDate] as? Date == stamp)
    }

    @Test func theSharedTabSaysWhatItGets() throws {
        let (home, appHome) = try folders()
        try skill("dataviz", in: home)
        try "{\"mcpServers\":{\"heron\":{\"command\":\"h\"}}}".write(to: home.appending(path: ".agents/mcp.json"),
                                                                    atomically: true, encoding: .utf8)
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, appHome, &record)

        let shot = PersonalDotAgents.snapshot(home: home, installed: ["antigravity"], record: record,
                                              appHomes: ["antigravity": appHome])

        #expect(shot.runtimes.map(\.id) == ["antigravity"])
        #expect(shot.skills.first?.reach["antigravity"]?.gets == true)
        #expect(shot.instructions?.reach["antigravity"]?.gets == false)
        #expect(shot.mcp.servers.first?.reach["antigravity"] == .gets("sent at start"))
        #expect(shot.needsALook.contains { $0.kind == .noFile && $0.item == "Antigravity" })
    }
}
