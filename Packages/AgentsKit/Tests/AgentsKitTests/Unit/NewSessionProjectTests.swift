import AgentsKitCore
import Foundation
import Testing

/// New Session at the top of the sidebar (#495, #2160).
@Suite("New Session's project")
struct NewSessionProjectTests {
    let a = ProjectKey(host: .mac, folder: URL(filePath: "/src/a"))
    let b = ProjectKey(host: .mac, folder: URL(filePath: "/src/b"))
    let server = ProjectKey(host: HostID(rawValue: "devbox"), folder: URL(filePath: "/src/b"))

    @Test func theRememberedProjectWinsWhileItIsLive() {
        let chosen = NewSessionProject.choose(live: [a, b], remembered: b, selected: a)
        #expect(chosen == NewSessionProject(key: b, why: .remembered))
    }

    /// The host is part of the project: the same folder on a server is another one.
    @Test func aServersProjectIsKeptWithItsHost() {
        let chosen = NewSessionProject.choose(live: [a, server], remembered: server, selected: a)
        #expect(chosen?.key.host == HostID(rawValue: "devbox"))
        #expect(chosen?.why == .remembered)
        // Kept in defaults and read back after a relaunch, it is still the server's.
        #expect(ProjectKey(stored: server.stored) == server)
        // The Mac's folder of the same name, remembered, is not live here: the selected one.
        #expect(NewSessionProject.choose(live: [a, server], remembered: b, selected: a)?.why == .selected)
    }

    @Test func thenTheSelectedThenTheFirst() {
        #expect(NewSessionProject.choose(live: [a, b], remembered: nil, selected: b) == NewSessionProject(key: b, why: .selected))
        #expect(NewSessionProject.choose(live: [a, b], remembered: nil, selected: nil) == NewSessionProject(key: a, why: .first))
        #expect(NewSessionProject.choose(live: [], remembered: a, selected: a) == nil)
    }
}
