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

    /// Two showings on screen at once (#2089): an iPhone's project screen over the sidebar
    /// of every project. The one on top holds it; when it goes, the one under it does again.
    @Test func whenTheTopShowingGoesTheOneUnderItHoldsThePage() {
        var hold = PageHold<URL>()
        let other = URL(filePath: "/tmp/other")
        let under = UUID(), over = UUID()
        hold.appeared(project, showing: under)
        hold.appeared(other, showing: over)
        #expect(hold.key == other)
        let went = hold.disappeared(over)
        #expect(went)
        #expect(hold.key == project)
    }

    /// What the top showing started opened in its place: the one under it holds the page.
    @Test func aReleaseGivesThePageToTheShowingUnderIt() {
        var hold = PageHold<URL>()
        let other = URL(filePath: "/tmp/other")
        let under = UUID(), over = UUID()
        hold.appeared(project, showing: under)
        hold.appeared(other, showing: over)
        hold.release()
        #expect(hold.key == project)
        let overWent = hold.disappeared(over)
        #expect(!overWent)
        #expect(hold.key == project)
    }

    /// A showing that went without saying so (#2089) is dropped once its page is no longer
    /// asked for, and does not hold the page from under the one on screen.
    @Test func aShowingWhosePageIsNotAskedForIsDropped() {
        var hold = PageHold<URL>()
        let other = URL(filePath: "/tmp/other")
        let ghost = UUID(), shown = UUID()
        hold.appeared(other, showing: ghost)
        hold.appeared(project, showing: shown)
        hold.keep { $0 == project }
        let went = hold.disappeared(shown)
        #expect(went)
        #expect(hold.key == nil)
    }

    /// A showing that comes again goes back on top, once.
    @Test func aShowingThatComesAgainHoldsThePageOnce() {
        var hold = PageHold<URL>()
        let other = URL(filePath: "/tmp/other")
        let first = UUID(), second = UUID()
        hold.appeared(project, showing: first)
        hold.appeared(other, showing: second)
        hold.appeared(project, showing: first)
        #expect(hold.key == project)
        _ = hold.disappeared(first)
        #expect(hold.key == other)
        _ = hold.disappeared(second)
        #expect(hold.key == nil)
    }
}
