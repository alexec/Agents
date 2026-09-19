import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Option cache")
struct OptionCacheTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsOptionCacheTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func entry(_ model: String, savedAt: Date = Date()) -> OptionCache.Entry {
        OptionCache.Entry(options: [ConfigOption(id: "model", name: "Model", category: "model",
                                                 type: "select", currentValue: .string(model),
                                                 options: [ConfigChoice(value: .string(model), name: model)])],
                          commands: [SlashCommand(name: "review")],
                          savedAt: savedAt)
    }

    @Test func whatWasSavedIsWhatComesBack() throws {
        let cache = OptionCache(locations: temporary())
        try cache.save(["claude\t/work\t": entry("a")])

        let loaded = cache.load()
        #expect(loaded.count == 1)
        #expect(loaded["claude\t/work\t"]?.options.first?.currentValue == .string("a"))
        #expect(loaded["claude\t/work\t"]?.commands.first?.name == "review")
    }

    @Test func nothingSavedIsNothingRemembered() {
        #expect(OptionCache(locations: temporary()).load().isEmpty)
    }

    @Test func aRuntimeAFolderAndItsServersAreWhatMakeTheAnswerTheSame() {
        let work = URL(fileURLWithPath: "/work")
        let server = MCPServer(name: "theirs", transport: .http(url: "https://example.com", headers: [:]))
        let plain = OptionCache.key(runtimeID: "claude", cwd: work, mcpServers: [])

        #expect(plain == OptionCache.key(runtimeID: "claude", cwd: URL(fileURLWithPath: "/work/"),
                                         mcpServers: []),
                "the same folder said two ways is one folder")
        #expect(plain != OptionCache.key(runtimeID: "copilot", cwd: work, mcpServers: []))
        #expect(plain != OptionCache.key(runtimeID: "claude", cwd: URL(fileURLWithPath: "/elsewhere"),
                                         mcpServers: []))
        #expect(plain != OptionCache.key(runtimeID: "claude", cwd: work, mcpServers: [server]),
                "a server can bring commands of its own with it")
    }

    @Test func theOldestAreForgottenRatherThanKeptForEver() throws {
        let cache = OptionCache(locations: temporary())
        var entries: [String: OptionCache.Entry] = [:]
        for i in 0..<(OptionCache.limit + 10) {
            entries["folder-\(i)"] = entry("a", savedAt: Date(timeIntervalSince1970: Double(i)))
        }
        try cache.save(entries)

        let loaded = cache.load()
        #expect(loaded.count == OptionCache.limit)
        #expect(loaded["folder-\(OptionCache.limit + 9)"] != nil, "the newest is kept")
        #expect(loaded["folder-0"] == nil, "the oldest is not")
    }

    @Test func aRuntimeThatOfferedNothingIsNotWorthRemembering() {
        #expect(!OptionCache.Entry(options: [], commands: []).isWorthKeeping)
        #expect(OptionCache.Entry(options: [], commands: [SlashCommand(name: "review")]).isWorthKeeping)
    }
}
