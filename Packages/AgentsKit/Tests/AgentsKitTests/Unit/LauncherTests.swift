import Testing
@testable import AgentsKitCore

/// The launcher home (#1090): the Home window choice as it is kept, and a project card's line.
@Suite("The launcher")
struct LauncherTests {
    @Test func theHomeWindowIsAllProjectsUntilLauncherIsKept() {
        #expect(HomeWindow(stored: nil) == .allProjects)
        #expect(HomeWindow(stored: "launcher") == .launcher)
        #expect(HomeWindow(stored: "tabs") == .allProjects, "anything else is the first state")
        #expect(DisplayPreference.mirrored[HomeWindow.defaultsKey] == .string, "the same on every client (#1033)")
    }

    @Test func aCardSaysWhatGoesOnAndIsIdleWithNothing() {
        #expect(LauncherCard.line(working: 3, needsYou: 1, unread: 2) == "3 working · 1 needs you · 2 unread")
        #expect(LauncherCard.line(working: 0, needsYou: 1, unread: 0) == "1 needs you")
        #expect(LauncherCard.line(working: 0, needsYou: 0, unread: 0) == "idle")
    }
}
