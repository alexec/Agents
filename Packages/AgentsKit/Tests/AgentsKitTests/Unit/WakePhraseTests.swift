import Testing
@testable import AgentsKitCore

/// #2420: "Hey Agents" opens voice mode, and words on the same breath are its first prompt.
@Suite("Hey Agents is heard")
struct WakePhraseTests {
    private let wake = WakePhrase.heyAgents

    @Test func thePhraseAloneWakes() {
        #expect(wake.wordsAfter(in: "Hey Agents.") == "")
        #expect(wake.wordsAfter(in: "hey agents") == "")
        #expect(wake.wordsAfter(in: "Hey, Agents!") == "")
    }

    @Test func wordsOnTheSameBreathAreThePrompt() {
        #expect(wake.wordsAfter(in: "Hey Agents, run the tests.") == "run the tests")
        #expect(wake.wordsAfter(in: "So. Hey agents what's on the board?") == "what's on the board")
    }

    @Test func howTheRecogniserWritesItWakes() {
        #expect(wake.wordsAfter(in: "Hey agent, fix the build") == "fix the build")
        #expect(wake.wordsAfter(in: "Hay agents") == "")
    }

    /// The spike's near misses (#1800): none of them wakes.
    @Test func nearMissesDoNotWake() {
        for sentence in [
            "Hey there, are the agents still running?",
            "Okay, agents can run in parallel now.",
            "The agents finished the build an hour ago.",
            "They agents said nothing.",
            "Hey, look at this graph, it went up again.",
            "Hey Lou, pass me the charger.",
        ] {
            #expect(wake.wordsAfter(in: sentence) == nil, "\(sentence)")
        }
    }
}
