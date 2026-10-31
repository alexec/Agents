#if !os(Linux)
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import AgentsKitCore
@testable import ControlDial

/// A hosted account's address refuses the connect outright (1003 CL-002/CL-003, #2235):
/// `Agents-Refusal` on the handshake's own answer, and the line itself, since a browser
/// or a `URLSessionWebSocketTask` reads no body off a failed upgrade, asked for again
/// plainly from `/readyz`.
@Suite("A refused connect's words", .timeLimit(.minutes(1)))
struct WebSocketLinkRefusalTests {
    /// A server that refuses every `/v1/connect` upgrade with `kind` and `body`, and
    /// answers `/readyz` with `readyz` (nil for a server that refuses that too).
    private func refusingServer(kind: String, body: String, readyz: String?) async throws -> RefusingServer {
        let channel = try await ServerBootstrap(group: ControlDial.group)
            .childChannelInitializer { channel in
                ControlWebSocketServer.configure(channel, tls: nil, reply: { head in
                    if head.uri == "/readyz", let readyz {
                        return PlainReply(.ok, Data(readyz.utf8), contentType: "text/plain; charset=utf-8")
                    }
                    if head.uri == "/readyz" { return PlainReply(.serviceUnavailable, Data()) }
                    return PlainReply(.forbidden, Data(body.utf8), contentType: "text/plain; charset=utf-8",
                                      headers: [(ControlRefusal.header, kind)])
                }, upgrade: { _ in false }, opened: { _ in })
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return RefusingServer(channel: channel)
    }

    private struct RefusingServer {
        let channel: any Channel
        var port: Int { channel.localAddress?.port ?? 0 }
        func stop() { channel.close(promise: nil) }
    }

    @Test func theLineComesFromReadyzWhenTheHandshakeCannotCarryIt() async throws {
        let server = try await refusingServer(kind: "suspended",
                                               body: "This hosted account is suspended. See https://example.com/account.\n",
                                               readyz: "This hosted account is suspended. See https://example.com/account.\n")
        defer { server.stop() }
        await #expect(throws: ControlRefusal(line: "This hosted account is suspended. See https://example.com/account.")) {
            _ = try await WebSocketLink.connect(URL(string: "http://127.0.0.1:\(server.port)")!, pin: nil)
        }
    }

    @Test func theKindStandsInWhenReadyzDoesNotAnswer() async throws {
        let server = try await refusingServer(kind: "limit", body: "Your Free plan allows 2 machines.", readyz: nil)
        defer { server.stop() }
        await #expect(throws: ControlRefusal(line: "limit")) {
            _ = try await WebSocketLink.connect(URL(string: "http://127.0.0.1:\(server.port)")!, pin: nil)
        }
    }

    @Test func theLineIsCutAtTwoHundredCharacters() async throws {
        let long = String(repeating: "x", count: 500)
        let server = try await refusingServer(kind: "limit", body: long, readyz: long)
        defer { server.stop() }
        await #expect(throws: ControlRefusal(line: String(repeating: "x", count: ControlRefusal.maxLineLength))) {
            _ = try await WebSocketLink.connect(URL(string: "http://127.0.0.1:\(server.port)")!, pin: nil)
        }
    }

    @Test func noHeaderIsAnOrdinaryFailureNotARefusal() async throws {
        let channel = try await ServerBootstrap(group: ControlDial.group)
            .childChannelInitializer { channel in
                ControlWebSocketServer.configure(channel, tls: nil, reply: { _ in
                    PlainReply(.internalServerError, Data())
                }, upgrade: { _ in false }, opened: { _ in })
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { channel.close(promise: nil) }
        let port = channel.localAddress?.port ?? 0
        await #expect {
            _ = try await WebSocketLink.connect(URL(string: "http://127.0.0.1:\(port)")!, pin: nil)
        } throws: { error in
            !(error is ControlRefusal)
        }
    }
}
#endif
