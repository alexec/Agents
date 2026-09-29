import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// This Mac's OpenCode sign-in, read for a server run to borrow (049 T031, D7).
@Suite("OpenCode's sign-in file, lent")
struct OpenCodeFileSignInTests {
    static let signIn = try! #require(RuntimeLaunchCatalog.opencode.lentSignIn)

    /// Keys, a well-known entry and a ChatGPT browser sign-in, as `opencode auth login` writes them.
    static let macFile = """
        {"anthropic":{"type":"api","key":"sk-ant-FAKE-mac-1111"},
         "openai":{"type":"oauth","refresh":"rt-FAKE","access":"at-FAKE","expires":1790000000000},
         "corp":{"type":"wellknown","key":"CORP_TOKEN","token":"wk-FAKE-2222"}}
        """

    static func home(_ file: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oc-signin-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try Data(file.utf8).write(to: folder.appendingPathComponent("auth.json")) }
        return home
    }

    static func object(_ text: String) throws -> [String: [String: String]] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]])
            .mapValues { $0.compactMapValues { $0 as? String } }
    }

    @Test func keysAndWellKnownEntriesAreLentAndABrowserSignInIsKeptAndNamed() throws {
        let home = try Self.home(Self.macFile)
        defer { try? FileManager.default.removeItem(at: home) }
        let reading = try #require(MacFileSignIn(runtimeID: "opencode", home: home.path, environment: [:])).read()
        #expect(reading.kept == ["openai"])
        #expect(reading.lent == ["anthropic", "corp"])
        #expect(reading.providers == 2)
        let lent = try Self.object(try #require(reading.lendable).reveal())
        #expect(lent.keys.sorted() == ["anthropic", "corp"])
        #expect(lent["anthropic"] == ["type": "api", "key": "sk-ant-FAKE-mac-1111"])
        #expect(!(try #require(reading.lendable).reveal().contains("rt-FAKE")))
        #expect(!(try #require(reading.lendable).reveal().contains("\n")), "compact, for one variable")
    }

    @Test func xdgDataHomeIsReadFirst() throws {
        let home = try Self.home(#"{"groq":{"type":"api","key":"gsk-FAKE-home"}}"#)
        let data = try Self.home(#"{"groq":{"type":"api","key":"gsk-FAKE-xdg"}}"#)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: data) }
        let file = try #require(MacFileSignIn(runtimeID: "opencode", home: home.path,
                                              environment: ["XDG_DATA_HOME": data.appendingPathComponent(".local/share").path]))
        #expect(file.read().lendable?.reveal().contains("gsk-FAKE-xdg") == true)
    }

    @Test func noFileLendsNothingAndAFileThatIsNotJSONSaysSo() throws {
        let none = try Self.home(nil)
        let junk = try Self.home("not json")
        defer { try? FileManager.default.removeItem(at: none); try? FileManager.default.removeItem(at: junk) }
        let empty = try #require(MacFileSignIn(runtimeID: "opencode", home: none.path, environment: [:])).read()
        #expect(empty.lendable == nil && !empty.unreadable)
        #expect(try #require(MacFileSignIn(runtimeID: "opencode", home: junk.path, environment: [:])).read().unreadable)
        #expect(MacFileSignIn(runtimeID: "claude") == nil, "only a runtime with a file sign-in")
    }

    @Test func aLentRunKeepsTheServersOwnKeysUnderTheMacsAndNeverItsBrowserSignIns() throws {
        let own = Data("""
            {"anthropic":{"type":"api","key":"sk-ant-FAKE-server"},
             "groq":{"type":"api","key":"gsk-FAKE-server"},
             "github-copilot":{"type":"oauth","refresh":"gho-FAKE","access":"x","expires":1}}
            """.utf8)
        let lent = try #require(Self.signIn.split(Data(Self.macFile.utf8))?.content)
        let merged = try Self.object(Self.signIn.merged(lent: lent, own: own))
        #expect(merged.keys.sorted() == ["anthropic", "corp", "groq"])
        #expect(merged["anthropic"]?["key"] == "sk-ant-FAKE-mac-1111", "the Mac's wins for the same provider")
        #expect(merged["groq"]?["key"] == "gsk-FAKE-server")
        #expect(try Self.object(Self.signIn.merged(lent: lent, own: nil)).keys.sorted() == ["anthropic", "corp"])
    }

    @Test func whatIsLentPrintsAsACountOnly() throws {
        let content = LentSignInContent(#"{"anthropic":{"type":"api","key":"sk-ant-FAKE-print"}}"#, providers: 1)
        let lend = DaemonAPI.SignInLend(runtime: "opencode", content: content)
        for text in ["\(content)", String(reflecting: content), "\(lend)", String(reflecting: lend)] {
            #expect(!text.contains("sk-ant-FAKE-print"), "\(text)")
        }
        var dumped = ""
        dump(lend, to: &dumped)
        dump(content, to: &dumped)
        #expect(!dumped.contains("sk-ant-FAKE-print"))
    }
}
