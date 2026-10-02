import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// How a host's join is said (#113), and the name a control plane on this Mac puts in codes.
@Suite("A host's join, in words")
struct HostJoinStatusTests {
    @Test func aFailedFirstJoinAndAFailedReconnectAreSaidApart() {
        let joining = DaemonAPI.HostJoinStatus(member: false, connected: false, problem: "nothing is listening at a.local:8791")
        #expect(joining.summary == "Couldn't join the control plane: nothing is listening at a.local:8791. Trying again…")
        let member = DaemonAPI.HostJoinStatus(member: true, connected: false, problem: "That code can't be used: spent.")
        #expect(member.summary == "Couldn't reach the control plane: That code can't be used: spent. Trying again…")
        #expect(!DaemonAPI.HostJoinStatus(member: true, connected: true).failed)
        #expect(!DaemonAPI.HostJoinStatus(member: false, connected: false).failed)
    }

    @Test func aRefusedCodeIsSaidInWords() {
        #expect(HostDialer.words(for: ControlAuth.Refusal(.expired)).hasPrefix("the host code has run out"))
        #expect(HostDialer.words(for: JSONRPCError(code: 1, message: "That code can't be used: spent.")) == "That code can't be used: spent.")
    }

    @Test func aFileIsReadOnlyForTheDaemonThatWroteIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let status = DaemonAPI.HostJoinStatus(member: false, connected: false, problem: "x")
        HostJoinFile(pid: getpid(), status: status).write(to: file)
        #expect(HostJoinFile.read(file, pid: getpid())?.problem == "x")
        #expect(HostJoinFile.read(file, pid: getpid() + 1) == nil)
        #expect(HostJoinFile.read(file)?.problem == "x")
        // A daemon that has gone: nothing to say.
        HostJoinFile(pid: 999_999, status: status).write(to: file)
        #expect(HostJoinFile.read(file) == nil)
    }

    /// The Unix host name may be one mDNS never answers for (`macos-<serial>`); the
    /// Bonjour name is the one codes carry.
    @Test func theLocalNameIsTheBonjourOne() throws {
        #expect(LocalHostName.fromHostName("macos-D3Q5YKXQXM") == "macos-d3q5ykxqxm.local")
        #expect(LocalHostName.fromHostName("Alexs-MacBook-Air.local") == "alexs-macbook-air.local")
        #expect(LocalHostName.fromHostName("box.example.com") == "box.local")
        #if os(macOS)
        let scutil = Process()
        scutil.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        scutil.arguments = ["--get", "LocalHostName"]
        let out = Pipe()
        scutil.standardOutput = out
        try scutil.run()
        let bonjour = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(LocalHostName.current == "\(bonjour).local".lowercased())
        #endif
    }
}
