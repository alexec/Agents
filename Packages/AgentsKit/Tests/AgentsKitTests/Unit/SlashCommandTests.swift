import Foundation
import Testing
@testable import AgentsKit

@Suite("Slash commands")
struct SlashCommandTests {
    private let commands = [
        SlashCommand(name: "add-dir", description: "Allow file access to a directory", inputHint: "directory"),
        SlashCommand(name: "review", description: "Run code review"),
        SlashCommand(name: "research", description: "Deep research", inputHint: "topic"),
        SlashCommand(name: "rubber-duck"),
    ]

    @Test func aSlashAtTheStartOfAWordBeginsACommand() {
        let query = SlashCommand.query(in: "/rev")
        #expect(query?.term == "rev")

        let afterSpace = SlashCommand.query(in: "please /rev")
        #expect(afterSpace?.term == "rev")
    }

    @Test func aSlashInsideAWordIsNotACommand() {
        // Otherwise typing a path turns the prompt into a command picker.
        #expect(SlashCommand.query(in: "look in /tmp/agent-demo") == nil)
        #expect(SlashCommand.query(in: "src/main.swift") == nil)
    }

    @Test func aFinishedWordIsNoLongerBeingTyped() {
        #expect(SlashCommand.query(in: "/review ") == nil)
        #expect(SlashCommand.query(in: "/review the diff") == nil)
    }

    @Test func aBareSlashOffersEverything() {
        let query = SlashCommand.query(in: "/")
        #expect(query?.term == "")
        #expect(SlashCommand.matching("", in: commands).count == 4)
    }

    @Test func whatStartsWithItComesFirst() {
        // Typed in the order the runtime advertised them, so only the rule can put
        // the prefix match on top.
        let list = [SlashCommand(name: "rubber-duck"), SlashCommand(name: "duck-pond")]
        #expect(SlashCommand.matching("duck", in: list).map(\.name) == ["duck-pond", "rubber-duck"])
    }

    @Test func onlyWhatMatchesIsOffered() {
        #expect(SlashCommand.matching("re", in: commands).map(\.name) == ["review", "research"])
        #expect(SlashCommand.matching("zz", in: commands).isEmpty)
    }

    @Test func matchingIgnoresCase() {
        #expect(SlashCommand.matching("REV", in: commands).first?.name == "review")
    }

    @Test func acceptingOneReplacesWhatWasTyped() {
        let text = "please /rev"
        let query = SlashCommand.query(in: text)!
        let completed = commands[1].completing(query, in: text)
        #expect(completed == "please /review ")
    }

    @Test func acceptingOneAtTheStartLeavesNothingBehind() {
        let text = "/add"
        let query = SlashCommand.query(in: text)!
        #expect(commands[0].completing(query, in: text) == "/add-dir ")
    }

    @Test func aCommandIsReadFromWhatTheRuntimeSent() {
        let wire: JSONValue = ["name": "add-dir",
                               "description": "Allow file access to a directory",
                               "input": ["hint": "directory"]]
        let command = SlashCommand(wire: wire)
        #expect(command?.name == "add-dir")
        #expect(command?.inputHint == "directory")
        #expect(SlashCommand(wire: ["description": "no name"]) == nil)
    }
}
