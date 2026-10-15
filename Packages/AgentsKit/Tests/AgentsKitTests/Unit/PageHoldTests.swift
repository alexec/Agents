import Foundation
import Testing
@testable import AgentsKitCore

/// The phone's New session works after the first time (#1044): the page that went late
/// does not let go of the page on screen.
@Suite("A page held by its showing")
struct PageHoldTests {
    private let project = URL(filePath: "/tmp/project")

    @Test func theFirstShowingOpensAndItsGoingLetsGo() {
        var hold = PageHold<URL>()
        let first = UUID()
        hold.appeared(project, showing: first)
        #expect(hold.key == project)
        let went = hold.disappeared(first)
        #expect(went)
        #expect(hold.key == nil)
    }

    /// The detail rebuilt: the new page came before the old one went.
    @Test func aLateGoingOfTheOldShowingKeepsTheNewOne() {
        var hold = PageHold<URL>()
        let old = UUID(), new = UUID()
        hold.appeared(project, showing: old)
        hold.appeared(project, showing: new)
        let oldWent = hold.disappeared(old)
        #expect(!oldWent)
        #expect(hold.key == project)
        let newWent = hold.disappeared(new)
        #expect(newWent)
        #expect(hold.key == nil)
    }

    /// The agent it started opened in its place, then New session again, after going to
    /// the background and back: a fresh open, and the old showing's going changes nothing.
    @Test func afterAReleaseTheNextShowingHoldsIt() {
        var hold = PageHold<URL>()
        let first = UUID()
        hold.appeared(project, showing: first)
        hold.release()
        #expect(hold.key == nil)
        hold.appeared(project, showing: UUID())
        let went = hold.disappeared(first)
        #expect(!went)
        #expect(hold.key == project)
    }
}
