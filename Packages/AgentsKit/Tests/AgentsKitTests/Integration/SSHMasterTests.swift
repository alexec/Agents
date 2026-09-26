import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// The one long-lived ssh connection per server (037), against the fake ssh.
    @Suite("The ssh master")
    struct SSHMasterTests {
        @Test func itIsReadyWhenTheMasterAnswersACheck() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let master = SSHMaster(command: fake.command(), socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            try await master.start(forwardingTo: nil)
            #expect(await master.isRunning)
            let check = try await fake.command().run(fake.command().controlArguments("check"))
            #expect(check.status == 0)
            await master.stop()
        }

        @Test func theForwardReachesWhateverListensOnTheServer() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let remote = fake.home.appendingPathComponent("r.sock")
            let listener = try EchoListener(path: remote.path)
            defer { listener.close() }
            let local = fake.hosts.appendingPathComponent("fk000001.sock")
            let master = SSHMaster(command: fake.command(), socket: local)
            try await master.start(forwardingTo: remote.path)
            await eventually("the forward socket exists") { FileManager.default.fileExists(atPath: local.path) }
            let reply = try EchoListener.roundTrip(path: local.path, line: "hello")
            #expect(reply == "HELLO")
            await master.stop()
        }

        @Test func stoppingRemovesBothSockets() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let local = fake.hosts.appendingPathComponent("fk000001.sock")
            let master = SSHMaster(command: fake.command(), socket: local)
            try await master.start(forwardingTo: fake.home.appendingPathComponent("nothing.sock").path)
            await master.stop()
            #expect(await master.isRunning == false)
            #expect(!FileManager.default.fileExists(atPath: fake.hosts.appendingPathComponent("fk000001.ctl").path))
            await eventually("the forward socket is gone") { !FileManager.default.fileExists(atPath: local.path) }
        }

        @Test(.flakyUnderLoad) func aMasterThatDiesIsNoticedWithinASecond() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let master = SSHMaster(command: fake.command(), socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            let exited = Flag()
            await master.setOnExit { await exited.set() }
            try await master.start(forwardingTo: nil)
            let pid = try #require(await master.pid)
            kill(pid, SIGKILL)
            await eventually("the exit was heard", within: .seconds(1)) { await exited.isSet }
            #expect(await master.isRunning == false)
        }

        @Test func staleFilesFromADeadMasterAreClearedFirst() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let ctl = fake.hosts.appendingPathComponent("fk000001.ctl")
            try "999999".write(to: ctl, atomically: true, encoding: .utf8)
            let master = SSHMaster(command: fake.command(), socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            try await master.start(forwardingTo: nil)
            #expect(await master.isRunning)
            await master.stop()
        }

        @Test func anUnreachableHostIsNamed() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let master = SSHMaster(command: fake.command(fail: "unknownHost"),
                                   socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            await #expect(throws: HostProblem.unknownHost) { try await master.start(forwardingTo: nil) }
        }

        @Test func aSocketPathTooLongIsRefusedBeforeSSHRuns() async throws {
            let long = URL(filePath: "/tmp/" + String(repeating: "x", count: 110) + ".sock")
            let master = SSHMaster(command: SSHCommand(name: "devbox", controlPath: URL(filePath: "/tmp/a.ctl")),
                                   socket: long)
            await #expect(throws: DaemonClient.ConnectError.self) { try await master.start(forwardingTo: "/r") }
        }

        actor Flag {
            var isSet = false
            func set() { isSet = true }
        }
    }
}

/// A Unix socket on the fake server that answers each line in capitals.
final class EchoListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = POSIX.unixStreamSocket()
        var address = POSIX.unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = self.fd
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = read(client, &buffer, buffer.count)
                if n > 0 {
                    let reply = Array(String(decoding: buffer[0..<n], as: UTF8.self).uppercased().utf8)
                    _ = reply.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                }
                POSIX.close(client)
            }
        }.start()
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        POSIX.close(fd)
        unlink(path)
    }

    static func roundTrip(path: String, line: String) throws -> String {
        let fd = POSIX.unixStreamSocket()
        defer { POSIX.close(fd) }
        var address = POSIX.unixAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                POSIX.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = Array(line.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }
}
