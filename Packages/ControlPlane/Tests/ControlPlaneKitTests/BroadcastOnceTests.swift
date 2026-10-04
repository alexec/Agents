import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// What happens on the control plane is said to its clients once (#172). A host's
/// connect was `control/hostChanged` twice (the router's online, then the hello's), and a
/// client's connect `control/clientChanged` twice (its link, then its admission), and the
/// window's Settings asks four questions for each.
@Suite("Each control-plane change is said once", .serialized, .timeLimit(.minutes(2)))
struct BroadcastOnceTests {
    let base = ControlServiceTests()

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [(method: String, params: JSONValue?)] = []
        func add(_ method: String, _ params: JSONValue?) { lock.withLock { notes.append((method, params)) } }
        func reset() { lock.withLock { notes = [] } }
        func count(_ method: String, where test: (JSONValue?) -> Bool = { _ in true }) -> Int {
            lock.withLock { notes.filter { $0.method == method && test($0.params) }.count }
        }
    }

    /// A client following the control plane's own notifications, as the window's
    /// Settings does.
    func watcher(_ running: ControlServiceTests.Running) async throws -> (Heard, ControlLink) {
        let (_, link) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client).text)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let heard = Heard()
        let notes = control.notifications()
        Task { for await note in notes { heard.add(note.method, note.params) } }
        return (heard, link)
    }

    @Test func aHostConnectingIsSaidOnce() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (heard, link) = try await watcher(running)
        defer { link.disconnect() }
        // The first host to join is made the home host, which is news of its own.
        let (home, first) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { first.stop() }
        await eventually { await running.service.methods.controlSettings.homeHost == home }

        let (host, uplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        // The hello comes after the uplink is up: give it time to have said anything it would.
        await eventually { await running.service.methods.host(host)?.machineID == "linux-1" }
        try await Task.sleep(for: .milliseconds(500))
        let online = heard.count(DaemonAPI.Notification.controlHostChanged) {
            $0?["host"]?.stringValue == host.rawValue && $0?["state"]?.stringValue == "online"
        }
        #expect(online == 1, "said \(online) times")
    }

    @Test func aClientReconnectingIsSaidOncePerChange() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (heard, watching) = try await watcher(running)
        defer { watching.disconnect() }

        let (id, link) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client).text)
        let other = DaemonClient(link: link.controlLink)
        try await other.connect(startIfNeeded: false)
        let about: (JSONValue?) -> Bool = { $0?["client"]?.stringValue == id.uuidString }
        await eventually { heard.count(DaemonAPI.Notification.controlClientChanged, where: about) >= 1 }
        try await Task.sleep(for: .milliseconds(300))

        // Gone and back: one word for each, not one more for the admission that changed nothing.
        heard.reset()
        link.disconnect()
        await eventually { heard.count(DaemonAPI.Notification.controlClientChanged, where: about) >= 1 }
        try await other.connect(startIfNeeded: false)
        await eventually { heard.count(DaemonAPI.Notification.controlClientChanged, where: about) >= 2 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(heard.count(DaemonAPI.Notification.controlClientChanged, where: about) == 2)
        link.disconnect()
    }
}
