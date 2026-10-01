import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Which home folder a daemon lays out (054, research R4): the real one only for the
/// ordinary daemon, a named one for a scratch copy that asks, and none otherwise.
@Suite("Personal home")
struct PersonalHomeTests {
    private let scratch = URL(fileURLWithPath: "/tmp/agents-scratch-root")

    @Test func aScratchRootGetsNoHome() {
        #expect(StoreLocations.personalHome(root: scratch, environment: [:]) == nil)
    }

    @Test func aScratchRootGetsTheHomeItNames() {
        let home = StoreLocations.personalHome(root: scratch,
                                               environment: [StoreLocations.personalHomeVariable: "/tmp/probe-home"])
        #expect(home?.path == "/tmp/probe-home")
    }

    @Test func anEmptyNameIsNoName() {
        #expect(StoreLocations.personalHome(root: scratch,
                                            environment: [StoreLocations.personalHomeVariable: ""]) == nil)
    }

    @Test func theOrdinaryRootGetsTheRealHome() {
        let home = StoreLocations.personalHome(root: StoreLocations.standardRoot, environment: [:])
        #expect(home?.path == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func aTestsOwnLocationsHaveNoHomeUnlessGivenOne() {
        var locations = StoreLocations(root: scratch)
        if ProcessInfo.processInfo.environment[StoreLocations.personalHomeVariable] == nil {
            #expect(locations.personalHome == nil)
        }
        locations.personalHome = URL(fileURLWithPath: "/tmp/given")
        #expect(locations.personalHome?.path == "/tmp/given")
    }
}
