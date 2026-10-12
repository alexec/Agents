import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A host linked to a provider's workspace (#691): the router lays its workspace over the
/// uplink's own state, so `hosts/list` and `control/hostChanged` say stopped, starting or
/// stopping, and carry the workspace, with no new `HostState`.
@Suite("A linked host's workspace over its state")
struct HostWorkspaceOverlayTests {
    let host = HostID(rawValue: "devbox01")

    func router() async throws -> (ControlRouter, ControlMethods) {
        let records = ControlRecords(store: MemoryStore())
        let settings = try await records.settings(orMake: { ControlSettings(name: "test", machineID: "m") })
        let methods = ControlMethods(records: records, settings: settings, version: "1")
        let router = ControlRouter(handler: methods)
        await methods.attach(router)
        try await methods.enroll(HostRecord(id: host, name: "devbox"))
        await router.know(host)
        return (router, methods)
    }

    func workspace(_ hostState: String?) -> DaemonAPI.HostWorkspace {
        DaemonAPI.HostWorkspace(provider: ProviderID(rawValue: "do-1"), providerName: "DigitalOcean",
                                workspace: "4101", workspaceName: "devbox", workspaceState: hostState ?? "running",
                                hostState: hostState, canStart: hostState == "stopped")
    }

    @Test func aStoppedWorkspaceIsShownStoppedWhileTheHostIsDown() async throws {
        let (router, methods) = try await router()
        await router.setWorkspace(workspace("stopped"), of: host)
        let described = await router.described(host, .offline(since: Date()))
        #expect(described["state"]?.stringValue == "stopped")
        #expect(described["workspace"]?["providerName"]?.stringValue == "DigitalOcean")
        let row = await methods.hostRow(try #require(await methods.host(host)))
        #expect(row.state == "stopped")
        #expect(row.workspace?.canStart == true)
    }

    @Test func anOnlineHostIsOnlineWhateverItsListSaid() async throws {
        let (router, _) = try await router()
        await router.setWorkspace(workspace("stopped"), of: host)
        #expect(await router.described(host, .online)["state"]?.stringValue == "online")
    }

    @Test func stoppingShowsEvenWhileTheHostIsOnline() async throws {
        let (router, _) = try await router()
        await router.setWorkspace(workspace("stopping"), of: host)
        #expect(await router.described(host, .online)["state"]?.stringValue == "stopping")
    }

    @Test func anUnlinkedHostIsDescribedAsBefore() async throws {
        let (router, _) = try await router()
        await router.setWorkspace(workspace("stopped"), of: host)
        await router.setWorkspace(nil, of: host)
        let described = await router.described(host, .offline(since: Date()))
        #expect(described["state"]?.stringValue == "offline")
        #expect(described["workspace"] == nil)
    }

    @Test func aRecordWrittenBeforeHasNoLink() throws {
        let old = #"{"id":"devbox01","name":"devbox","reach":{"dialOut":{}},"platform":"","version":"","installed":false,"rev":1}"#
        #expect(try ControlRecords.decoder.decode(HostRecord.self, from: Data(old.utf8)).workspace == nil)
    }

    @Test func aProviderIDIsASlugOfItsName() {
        let id = ProviderID.make(name: "Docker on this Mac!").rawValue
        #expect(id.hasPrefix("docker-on-this-mac-"))
        #expect(id.count == "docker-on-this-mac-".count + 4)
        #expect(ProviderID.make(name: "☁️").rawValue.hasPrefix("provider-"))
    }
}
