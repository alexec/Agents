import Foundation
import Testing
@testable import AgentsKitCore

/// Connect to Another… (#4228): what Hosted sends back on agents://hosted, and which pasted
/// code will do.
@Suite("Connect to Another")
struct ConnectAnotherTests {
    private func code(_ purpose: ControlCode.Purpose) -> ControlCode {
        ControlCode(purpose: purpose, controlKey: Data(repeating: 4, count: 65), secret: Data(repeating: 7, count: 32),
                    url: "https://k3v9x0qa7b.cp.agentloops.dev", pin: nil, name: "k3v9x0qa7b")
    }

    /// Escaped as Go's escapeCode does: every byte but the unreserved ones.
    private func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    @Test func hostedSendsAClientCode() {
        let sent = code(.client)
        let url = URL(string: "agents://hosted#code=" + escaped(sent.text))!
        #expect(ConnectAnother.answer(url) == .code(sent))
        #expect(ConnectAnother.place(sent) == "k3v9x0qa7b.cp.agentloops.dev")
    }

    @Test func aControlPlaneAtAnIPAddressGoesByItsName() {
        var atIP = code(.client)
        atIP.url = "https://127.0.0.1:52760"
        #expect(ConnectAnother.place(atIP) == "k3v9x0qa7b")
        atIP.url = "https://[::1]:52760"
        #expect(ConnectAnother.place(atIP) == "k3v9x0qa7b")
    }

    @Test func hostedSaysWhyNot() {
        let url = URL(string: "agents://hosted#message=" + escaped("The service is full just now."))!
        #expect(ConnectAnother.answer(url) == .failed("The service is full just now."))
        #expect(ConnectAnother.answer(URL(string: "agents://hosted")!) == .failed(ConnectAnother.Words.hostedNoCode))
        let machine = URL(string: "agents://hosted#code=" + escaped(code(.host).text))!
        #expect(ConnectAnother.answer(machine) == .failed(ConnectAnother.Words.hostedNoCode))
    }

    @Test func aPastedCodeMustBeAClientCode() throws {
        #expect(try ConnectAnother.check("  " + code(.client).text + "\n").get() == code(.client))
        #expect(ConnectAnother.check("AGT-123") == .failure(.init(words: ConnectAnother.Words.notACode)))
        #expect(ConnectAnother.check(code(.host).text) == .failure(.init(words: ConnectAnother.Words.machineCode)))
    }
}
