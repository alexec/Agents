import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server, as the window remembers it (037).
///
/// The name is handed to `ssh` as the destination, so the rules here are what keep a
/// typed name from ever being read as an option.
@Suite("A host and its name")
struct HostTests {
    @Test func aNameIsWhatSSHIsGiven() throws {
        let host = try Host(sshName: "devbox")
        #expect(host.sshName == "devbox")
        #expect(host.label == "devbox")
    }

    @Test func theLabelIsTheHostPartOfUserAtHost() throws {
        #expect(try Host(sshName: "alex@devbox.lan:2222").label == "devbox.lan")
        #expect(try Host(sshName: "alex@devbox.lan").label == "devbox.lan")
        #expect(try Host(sshName: "gpu-01:2200").label == "gpu-01")
    }

    @Test(arguments: ["", "  ", "dev box", "-oProxyCommand=evil", "devbox\n", "\tdevbox"])
    func aNameThatCouldBeAnOptionOrIsNotOneWordIsRefused(_ name: String) {
        #expect(throws: Host.InvalidName.self) { try Host(sshName: name) }
    }

    @Test func anIDIsEightLowercaseLettersOrDigits() throws {
        for _ in 0..<50 {
            let id = HostID.make()
            #expect(id.rawValue.count == 8)
            #expect(id.rawValue.allSatisfy { $0.isLowercase || $0.isNumber })
            #expect(id.rawValue.allSatisfy { $0.isASCII })
            #expect(id != .mac)
        }
    }

    @Test func twoHostsMayNotShareAName() throws {
        var hosts = HostList()
        try hosts.add(Host(sshName: "devbox"))
        #expect(throws: HostList.Duplicate.self) { try hosts.add(Host(sshName: "devbox")) }
        try hosts.add(Host(sshName: "gpu-01"))
        #expect(hosts.all.map(\.sshName) == ["devbox", "gpu-01"])
    }

    @Test func thisMacIsNeverWrittenDown() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HostStore(file: folder.appendingPathComponent("hosts.json"))
        var hosts = HostList()
        try hosts.add(Host(sshName: "devbox"))
        try store.save(hosts)
        let text = try String(contentsOf: folder.appendingPathComponent("hosts.json"), encoding: .utf8)
        #expect(!text.contains("\"mac\""))
        #expect(store.load().all.map(\.sshName) == ["devbox"])
    }

    @Test func aMissingFileIsNoServers() {
        let store = HostStore(file: URL(filePath: "/nonexistent/\(UUID().uuidString)/hosts.json"))
        #expect(store.load().all.isEmpty)
    }

    @Test func aProjectKeyIsWrittenAsHostBarPath() {
        let key = ProjectKey(host: HostID(rawValue: "ab12cd34"), folder: URL(filePath: "/home/alex/src/api"))
        #expect(key.stored == "ab12cd34|/home/alex/src/api")
        #expect(ProjectKey(stored: key.stored) == key)
    }

    @Test func aBarePathIsThisMacs() {
        let key = ProjectKey(stored: "/Users/alex/src/api")
        #expect(key?.host == .mac)
        #expect(key?.folder.path == "/Users/alex/src/api")
    }

    @Test func theSamePathOnTwoHostsIsTwoProjects() {
        let path = URL(filePath: "/home/alex/src/api")
        let one = ProjectKey(host: HostID(rawValue: "aaaaaaaa"), folder: path)
        let two = ProjectKey(host: HostID(rawValue: "bbbbbbbb"), folder: path)
        #expect(one != two)
        #expect(Set([one, two]).count == 2)
    }
}
