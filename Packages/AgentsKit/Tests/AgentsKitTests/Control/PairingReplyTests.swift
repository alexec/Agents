import Foundation
import Testing
@testable import AgentsKitCore

/// The window's Pair a Device sheet asks `devices/startPairing` for the code its QR shows.
/// A control plane answers with its own device code, a Mac of the first build with its
/// bridge code; the sheet shows either (2026-10-01: it read only the second, so a window
/// on a control plane showed no code at all).
@Suite("Pair a Device's reply")
struct PairingReplyTests {
    @Test func aControlPlanesDeviceCodeIsShown() async throws {
        let code = ControlCode(purpose: .client(.device), controlKey: Data([0x04] + Array(repeating: 7, count: 64)),
                               secret: Data(repeating: 9, count: 32), url: "https://mac.local:8791",
                               pin: ControlCode.base64url(Data(repeating: 1, count: 32)), name: "Mac")
        let methods = ControlMethods(records: ControlRecords(store: MemoryStore()),
                                     settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        var hooks = ControlMethods.Hooks()
        hooks.startPairing = { grant in
            try JSONValue.encoding(DaemonAPI.ControlCodeShown(
                text: grant == .device ? code.text : "", expires: Date(timeIntervalSince1970: 1_000)))
        }
        await methods.setHooks(hooks)
        let window = ControlRouter.Caller(session: UUID(), client: UUID(), grant: .operator, kind: .mac)

        let reply = try await methods.handle(method: DaemonAPI.Method.devicesStartPairing, params: nil, from: window)

        #expect((try? reply.decode(DaemonAPI.PairingCode.self)) == nil)
        let shown = try DaemonAPI.ControlCodeShown(pairingReply: reply)
        #expect(shown.text == code.text)
        let read = try #require(ControlCode(text: shown.text))
        #expect(read.purpose == .client(.device))
        #expect(read.url == "https://mac.local:8791")
    }

    @Test func aFirstBuildMacsBridgeCodeIsShown() throws {
        let code = DaemonAPI.PairingCode(macKey: Data([0x04] + Array(repeating: 7, count: 64)),
                                         secret: Data(repeating: 9, count: 32), name: "Mac",
                                         expires: Date(timeIntervalSince1970: 1_000))
        let shown = try DaemonAPI.ControlCodeShown(pairingReply: try JSONValue.encoding(code))
        #expect(shown.text == code.text)
        #expect(shown.expires == code.expires)
    }
}
