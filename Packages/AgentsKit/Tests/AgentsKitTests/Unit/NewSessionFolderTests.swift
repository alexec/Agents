import AgentsKitCore
import Foundation
import Testing

/// New Session at the top of the sidebar (#495, #2160).
@Suite("New Session's folder")
struct NewSessionFolderTests {
    let a = FolderKey(host: .mac, folder: URL(filePath: "/src/a"))
    let b = FolderKey(host: .mac, folder: URL(filePath: "/src/b"))
    let server = FolderKey(host: MachineRef(rawValue: "devbox"), folder: URL(filePath: "/src/b"))

    @Test func theRememberedFolderWinsWhileItIsLive() {
        let chosen = NewSessionFolder.choose(live: [a, b], remembered: b, selected: a)
        #expect(chosen == NewSessionFolder(key: b, why: .remembered))
    }

    /// The host is part of the folder: the same folder on a server is another one.
    @Test func aServersFolderIsKeptWithItsHost() {
        let chosen = NewSessionFolder.choose(live: [a, server], remembered: server, selected: a)
        #expect(chosen?.key.host == MachineRef(rawValue: "devbox"))
        #expect(chosen?.why == .remembered)
        // Kept in defaults and read back after a relaunch, it is still the server's.
        #expect(FolderKey(stored: server.stored) == server)
        // The Mac's folder of the same name, remembered, is not live here: the selected one.
        #expect(NewSessionFolder.choose(live: [a, server], remembered: b, selected: a)?.why == .selected)
    }

    @Test func thenTheSelectedThenTheFirst() {
        #expect(NewSessionFolder.choose(live: [a, b], remembered: nil, selected: b) == NewSessionFolder(key: b, why: .selected))
        #expect(NewSessionFolder.choose(live: [a, b], remembered: nil, selected: nil) == NewSessionFolder(key: a, why: .first))
        #expect(NewSessionFolder.choose(live: [], remembered: a, selected: a) == nil)
    }
}
