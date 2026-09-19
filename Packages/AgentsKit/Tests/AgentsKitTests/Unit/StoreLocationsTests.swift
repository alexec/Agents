import Foundation
import Testing
@testable import AgentsKit

/// Which daemon a process belongs to.
///
/// The root is the whole of a daemon's identity, so the rule that picks it is the rule
/// that decides whether a second copy of the app is a second daemon or a fight over
/// the first one's lock. It is a pure function for exactly that reason.
@Suite("Which daemon this process belongs to")
struct StoreLocationsTests {
    @Test func withNothingSaidItIsTheOrdinaryPlace() {
        let chosen = StoreLocations.chosen(arguments: ["agentsd"], environment: [:])
        #expect(chosen.root.path == StoreLocations.standard.root.path)
        #expect(chosen.isStandard)
    }

    @Test func anArgumentNamesTheRoot() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "/tmp/branch"],
                                           environment: [:])
        #expect(chosen.root.path == "/tmp/branch")
        #expect(!chosen.isStandard)
        #expect(chosen.name == "branch")
    }

    @Test func theEqualsFormIsTheSameArgument() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root=/tmp/branch"],
                                           environment: [:])
        #expect(chosen.root.path == "/tmp/branch")
    }

    @Test func theVariableNamesItToo() {
        let chosen = StoreLocations.chosen(arguments: ["agentsd"],
                                           environment: ["AGENTS_ROOT": "/tmp/branch"])
        #expect(chosen.root.path == "/tmp/branch")
    }

    /// The argument wins because it is the one that survives `open`: macOS passes a
    /// second copy of a bundle its arguments and not its environment.
    @Test func theArgumentBeatsTheVariable() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "/tmp/asked"],
                                           environment: ["AGENTS_ROOT": "/tmp/inherited"])
        #expect(chosen.root.path == "/tmp/asked")
    }

    /// An empty value is somebody's mistake, not a request for the current directory.
    @Test func anEmptyRootIsIgnored() {
        #expect(StoreLocations.chosen(arguments: ["Agents", "--root", ""], environment: [:])
            .root.path == StoreLocations.standard.root.path)
        #expect(StoreLocations.chosen(arguments: ["agentsd"], environment: ["AGENTS_ROOT": ""])
            .root.path == StoreLocations.standard.root.path)
    }

    @Test func aTildeIsAHomeDirectory() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "~/Agents-branch"],
                                           environment: [:])
        #expect(chosen.root.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(chosen.name == "Agents-branch")
    }

    /// Everything that makes a daemon a daemon hangs off the root, which is why two
    /// roots cannot collide over a lock, a socket, or an agent's record.
    @Test func twoRootsShareNothing() {
        let one = StoreLocations(root: URL(filePath: "/tmp/one"))
        let two = StoreLocations(root: URL(filePath: "/tmp/two"))
        #expect(one.socket.path != two.socket.path)
        #expect(one.lock.path != two.lock.path)
        #expect(one.log.path != two.log.path)
        #expect(one.agents.path != two.agents.path)
        #expect(one.projects.path != two.projects.path)
    }
}
