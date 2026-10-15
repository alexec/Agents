import Testing
@testable import AgentsKitCore

/// Add as Host… offers Link to existing host (#976) for a host whose name is the workspace's
/// ssh destination, or holds the workspace's name as whole dot-separated parts.
@Suite("A workspace and a host added by hand")
struct WorkspaceHostMatchTests {
    let workspace = DaemonAPI.WorkspaceInfo(id: "w1", name: "devstack-d7539e59", state: "running",
                                            ssh: "cws.devstack-d7539e59")

    @Test func theSshAliasMatches() {
        #expect(workspace.mayBe(hostNamed: "cws.devstack-d7539e59"))
        #expect(workspace.mayBe(hostNamed: "CWS.devstack-d7539e59"))
    }

    @Test func aWholePartMatches() {
        let bare = DaemonAPI.WorkspaceInfo(id: "w1", name: "devstack-d7539e59", state: "running")
        #expect(bare.mayBe(hostNamed: "devstack-d7539e59"))
        #expect(bare.mayBe(hostNamed: "cws.devstack-d7539e59"))
        #expect(bare.mayBe(hostNamed: "devstack-d7539e59.example.com"))
    }

    @Test func aPartOfAPartDoesNotMatch() {
        let dev = DaemonAPI.WorkspaceInfo(id: "w2", name: "dev", state: "running")
        #expect(!dev.mayBe(hostNamed: "devstack"))
        #expect(!dev.mayBe(hostNamed: "cws.devstack-d7539e59"))
        #expect(!workspace.mayBe(hostNamed: "devstack"))
    }

    @Test func aDottedNameMatchesAsWholeParts() {
        let dotted = DaemonAPI.WorkspaceInfo(id: "w3", name: "box.lan", state: "running")
        #expect(dotted.mayBe(hostNamed: "ssh.box.lan"))
        #expect(!dotted.mayBe(hostNamed: "bigbox.lan"))
    }
}
