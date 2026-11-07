import CoreGraphics
import Foundation
import Testing
@testable import AgentsKitCore

/// The machine's browser on a client (#3528): where a click lands in the page, what a key
/// says, and that what the client sends is what the schema says.
@Suite("Machine browser")
struct MachineBrowserTests {
    @Test func aClickLandsWhereThePageIsDrawn() {
        // An 800×600 page in a 400×600 view: drawn 400×300, 150 points down.
        let page = CGSize(width: 800, height: 600)
        let view = CGSize(width: 400, height: 600)
        #expect(MachineBrowser.fitted(page, in: view) == CGRect(x: 0, y: 150, width: 400, height: 300))
        #expect(MachineBrowser.pagePoint(CGPoint(x: 200, y: 300), in: view, page: page) == CGPoint(x: 400, y: 300))
        #expect(MachineBrowser.pagePoint(CGPoint(x: 0, y: 150), in: view, page: page) == .zero)
        // Above the page, and with no page yet: nowhere.
        #expect(MachineBrowser.pagePoint(CGPoint(x: 200, y: 100), in: view, page: page) == nil)
        #expect(MachineBrowser.pagePoint(CGPoint(x: 1, y: 1), in: view, page: .zero) == nil)
    }

    @Test func aKeyIsNamedAsThePageNamesIt() {
        let a = BrowserKeys.input(down: true, characters: "a", bare: "a", macKeyCode: 0, modifiers: 0)
        #expect(a.key == "a" && a.code == "KeyA" && a.keyCode == 65 && a.text == "a" && a.type == "keyDown")
        let up = BrowserKeys.input(down: false, characters: "a", bare: "a", macKeyCode: 0, modifiers: 0)
        #expect(up.type == "keyUp" && up.text == nil)
        let shifted = BrowserKeys.input(down: true, characters: "A", bare: "A", macKeyCode: 0,
                                        modifiers: BrowserKeys.modifiers(option: false, control: false, command: false, shift: true))
        #expect(shifted.key == "A" && shifted.code == "KeyA" && shifted.text == "A" && shifted.modifiers == 8)
        let seven = BrowserKeys.input(down: true, characters: "7", bare: "7", macKeyCode: 26, modifiers: 0)
        #expect(seven.code == "Digit7" && seven.keyCode == 55)
        // Keys with no text: named, with the code Chromium acts on, and no text.
        let back = BrowserKeys.input(down: true, characters: "\u{7F}", bare: "\u{7F}", macKeyCode: 51, modifiers: 0)
        #expect(back.key == "Backspace" && back.keyCode == 8 && back.text == nil)
        let enter = BrowserKeys.input(down: true, characters: "\r", bare: "\r", macKeyCode: 36, modifiers: 0)
        #expect(enter.key == "Enter" && enter.keyCode == 13)
        let left = BrowserKeys.input(down: true, characters: "\u{F702}", bare: "\u{F702}", macKeyCode: 123, modifiers: 0)
        #expect(left.key == "ArrowLeft" && left.keyCode == 37 && left.text == nil)
        let space = BrowserKeys.input(down: true, characters: " ", bare: " ", macKeyCode: 49, modifiers: 0)
        #expect(space.code == "Space" && space.text == " ")
        // A shortcut types nothing.
        let command = BrowserKeys.input(down: true, characters: "a", bare: "a", macKeyCode: 0,
                                        modifiers: BrowserKeys.modifiers(option: false, control: false, command: true, shift: false))
        #expect(command.text == nil && command.modifiers == 4 && command.code == "KeyA")
    }

    @Test func whatTheClientSendsIsWhatTheSchemaSays() throws {
        let schema = try WireSchema(WireSchemaTests.read("daemon.schema.json"))
        func check(_ value: some Encodable, _ name: String) throws {
            let json = try JSONValue.parse(JSONEncoder().encode(value))
            #expect(schema.errors(json, against: name) == [], "\(name)")
        }
        try check(DaemonAPI.BrowserWatchRequest(width: 400, height: 600), "BrowserWatchRequest")
        try check(DaemonAPI.BrowserAckRequest(ack: 3), "BrowserAckRequest")
        try check(DaemonAPI.BrowserNavigateRequest(action: .go, url: "example.com"), "BrowserNavigateRequest")
        try check(DaemonAPI.BrowserNavigateRequest(action: .back), "BrowserNavigateRequest")
        try check(DaemonAPI.BrowserInputRequest(kind: .mouse, type: "mousePressed", x: 1.5, y: 2, button: "left",
                                                clickCount: 1, modifiers: 0), "BrowserInputRequest")
        try check(DaemonAPI.BrowserInputRequest(kind: .wheel, x: 1, y: 2, deltaX: 0, deltaY: 40), "BrowserInputRequest")
        try check(BrowserKeys.input(down: true, characters: "a", bare: "a", macKeyCode: 0, modifiers: 0), "BrowserInputRequest")
        try check(DaemonAPI.BrowserInputRequest(kind: .text, text: "pasted"), "BrowserInputRequest")
        try check(DaemonAPI.BrowserPageState(status: .starting, detail: "Downloading Chromium"), "BrowserPageState")
        try check(DaemonAPI.BrowserWatchRequest(width: 400, height: 600, agent: UUID()), "BrowserWatchRequest")
        try check(DaemonAPI.BrowserPageState(status: .running, noTab: true, holder: UUID(), holderTitle: "Sign up"),
                  "BrowserPageState")
        try check(DaemonAPI.BrowserFrame(image: Data([0xFF, 0xD8]), ack: 1, width: 800, height: 600), "BrowserFrame")
    }

    /// #3916: a session's pane shows its own tab, says who else holds the browser, and
    /// opens when its agent starts to use it.
    @Test func aPaneSaysWhoElseHoldsTheBrowser() {
        let me = UUID(), other = UUID()
        #expect(DaemonAPI.BrowserPageState(status: .running, holder: other).otherHolder(than: me) == other)
        #expect(DaemonAPI.BrowserPageState(status: .running, holder: me).otherHolder(than: me) == nil)
        #expect(DaemonAPI.BrowserPageState(status: .running).otherHolder(than: me) == nil)
        #expect(DaemonAPI.BrowserPageState(status: .running, noTab: true).sessionHasNoTab)
        #expect(!DaemonAPI.BrowserPageState(status: .stopped, noTab: true).sessionHasNoTab)
    }

    @Test func thePaneOpensForANewerUseOfTheBrowser() {
        let started = Date(timeIntervalSince1970: 1000)
        let before = started.addingTimeInterval(-60), after = started.addingTimeInterval(60)
        // A use from before this client started opens nothing; one after it does.
        #expect(!BrowserUse.opensPane(usedAt: before, seen: nil, since: started))
        #expect(BrowserUse.opensPane(usedAt: after, seen: nil, since: started))
        #expect(!BrowserUse.opensPane(usedAt: nil, seen: nil, since: started))
        // Once seen, only a newer one: a pane the person closed stays closed for this turn.
        #expect(!BrowserUse.opensPane(usedAt: after, seen: after, since: started))
        #expect(BrowserUse.opensPane(usedAt: after.addingTimeInterval(1), seen: after, since: started))
        // This client started when its process did, before anything here read it.
        #expect(BrowserUse.clientStarted < Date())
        #expect(Date().timeIntervalSince(BrowserUse.clientStarted) < 24 * 3600)
    }

    @Test func anAgentKeepsWhenItUsedTheBrowser() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp/x"))
        agent.browserUsedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let back = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(back.browserUsedAt == agent.browserUsedAt)
    }

    @Test func aStatusThisBuildDoesNotKnowIsStopped() throws {
        let s = try JSONDecoder().decode(DaemonAPI.BrowserPageState.self, from: Data(#"{"status":"paused"}"#.utf8))
        #expect(s.status == .stopped)
    }
}
