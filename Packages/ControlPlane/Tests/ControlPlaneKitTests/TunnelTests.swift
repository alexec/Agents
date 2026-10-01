import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Darwin
import Foundation
import Testing

/// A sign-in relayed between hosts through the control plane (058, T091): a tunnel from the
/// borrowing host to the lending one's relay, opened only for a lend an operator allowed.
@Suite("Tunnels between hosts for a relayed sign-in", .serialized, .timeLimit(.minutes(2)))
struct TunnelTests {
    let base = ControlServiceTests()

    /// A stand-in for the Mac's relay: a loopback port that says back what it is sent.
    final class Echo: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32

        init() throws {
            let made = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(made, 4)
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &length) } }
            fd = made
            port = UInt16(bigEndian: bound.sin_port)
            let listener = fd
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    Thread {
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = read(client, &buffer, 4096)
                            if n <= 0 { break }
                            _ = write(client, buffer, n)
                        }
                        close(client)
                    }.start()
                }
            }.start()
        }

        func stop() { close(fd) }
    }

    func operatorControl(_ running: ControlServiceTests.Running) async throws -> (DaemonClient, ControlLink) {
        let (_, link) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client(.operator)).text)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        return (control, link)
    }

    @Test func bytesGoThroughATunnelAnOperatorAllowed() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (lender, lenderUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { lenderUplink.stop() }
        let (borrower, borrowerUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { borrowerUplink.stop() }
        let echo = try Echo()
        defer { echo.stop() }
        lenderUplink.setLendingPort { runtime in runtime == "claude" ? echo.port : nil }
        await eventually { await running.service.router.state(of: lender)?.isOnline == true }
        await eventually { await running.service.router.state(of: borrower)?.isOnline == true }

        // Not allowed yet: refused, and nothing opened.
        await #expect(throws: JSONRPCError.self) { _ = try await borrowerUplink.openTunnel(runtime: "claude") }
        #expect(await running.service.router.tunnels().isEmpty)

        let (control, link) = try await operatorControl(running)
        defer { link.disconnect() }
        _ = try await control.call(DaemonAPI.Method.hostsLendSignIn,
                                   DaemonAPI.LendSignIn(host: borrower, from: lender, runtime: "claude", allowed: true))

        // Allowed: bytes there and back, as they were sent.
        let tunnel = try await borrowerUplink.openTunnel(runtime: "claude")
        let hello = Data("GET / HTTP/1.1\r\nHost: api\r\n\r\n".utf8) + Data((0..<200).map { UInt8($0) })
        try tunnel.write(line: TunnelPipe.line(hello))
        var back = Data()
        for try await line in tunnel.lines() {
            back += TunnelPipe.bytes(line) ?? Data()
            if back.count >= hello.count { break }
        }
        #expect(back == hello)
        #expect(await running.service.router.tunnels().count == 2)

        // Closed at the borrower: gone at both ends.
        tunnel.close()
        await eventually { await running.service.router.tunnels().isEmpty }
        #expect(await running.service.router.tunnels().isEmpty)

        // Taken back: refused again.
        _ = try await control.call(DaemonAPI.Method.hostsLendSignIn,
                                   DaemonAPI.LendSignIn(host: borrower, from: lender, runtime: "claude", allowed: false))
        await #expect(throws: JSONRPCError.self) { _ = try await borrowerUplink.openTunnel(runtime: "claude") }
    }

    @Test func onlyAnOperatorAllowsALend() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (lender, lenderUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { lenderUplink.stop() }
        let (borrower, borrowerUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { borrowerUplink.stop() }
        let (_, deviceLink) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client(.device)).text)
        defer { deviceLink.disconnect() }
        let device = DaemonClient(link: deviceLink.controlLink)
        try await device.connect(startIfNeeded: false)
        await #expect(throws: JSONRPCError.self) {
            _ = try await device.call(DaemonAPI.Method.hostsLendSignIn,
                                      DaemonAPI.LendSignIn(host: borrower, from: lender, runtime: "claude", allowed: true))
        }
    }

    @Test func aChunkIsAJSONStringOfItsBase64() {
        let bytes = Data([0, 1, 2, 250, 255])
        let line = TunnelPipe.line(bytes)
        #expect(line.hasPrefix("\"") && line.hasSuffix("\""))
        #expect(TunnelPipe.bytes(line) == bytes)
        #expect(TunnelPipe.bytes("{\"jsonrpc\":\"2.0\"}") == nil)
    }
}
