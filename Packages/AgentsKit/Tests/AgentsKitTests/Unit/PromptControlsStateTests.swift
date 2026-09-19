import Foundation
import Testing
@testable import AgentsKitCore

/// What the area under the prompt says, in every state it can be in.
///
/// The bug this guards is not any one of these cases. It is the seventh one nobody
/// thought of arriving in a year and coming out as a silent gap, the way the first six
/// did. So the test that matters is `everyCaseIsDrawn`: a switch with no `default`,
/// which stops compiling the day someone adds a case without deciding what it says.
@Suite("What the controls under the prompt say")
struct PromptControlsStateTests {
    private func select(_ id: String, category: String?, values: [String] = ["a", "b"]) -> ConfigOption {
        ConfigOption(id: id, name: id.capitalized, category: category, type: "select",
                     currentValue: .string(values[0]),
                     options: values.map { ConfigChoice(value: .string($0), name: $0.uppercased()) })
    }

    private func resolve(agent: [ConfigOption]? = nil,
                         draft: [ConfigOption] = [],
                         folder: Bool = true,
                         runtime: Bool = true,
                         name: String? = "Claude",
                         loading: Bool = false,
                         failure: String? = nil) -> PromptControlsState {
        PromptControlsState.resolve(agentOptions: agent, draftOptions: draft,
                                    hasFolder: folder, hasRuntime: runtime,
                                    runtimeName: name, isLoading: loading, failure: failure)
    }

    /// The one that carries the feature.
    ///
    /// Every case is reachable from `resolve`, and the switch below has no `default`,
    /// so a new case cannot be added without a decision about what the person reads.
    @Test func everyCaseIsDrawn() {
        let reached: [PromptControlsState] = [
            resolve(folder: false),
            resolve(runtime: false),
            resolve(loading: true),
            resolve(failure: "The runtime did not answer."),
            resolve(draft: []),
            resolve(draft: [select("mode", category: "mode")]),
        ]
        var seen: Set<String> = []
        for state in reached {
            switch state {
            case .needsFolder: seen.insert("needsFolder")
            case .needsRuntime: seen.insert("needsRuntime")
            case .loading: seen.insert("loading")
            case .failed: seen.insert("failed")
            case .nothingOffered: seen.insert("nothingOffered")
            case .controls: seen.insert("controls")
            }
        }
        #expect(seen.count == 6, "every case is reachable, and each one says something")
    }

    /// The `??` bug. An agent with an empty list is not an answer about its runtime,
    /// so it must fall through rather than becoming a row of nothing.
    @Test func anAgentWithNoOptionsFallsThroughRatherThanShowingARow() {
        let draft = [select("model", category: "model")]
        #expect(resolve(agent: [], draft: draft) == .controls(draft))
        #expect(resolve(agent: [], draft: [], loading: true) == .loading(runtimeName: "Claude"))
        #expect(resolve(agent: [], draft: [], failure: "no") == .failed(reason: "no"))
    }

    /// Cursor's case, every time, by design.
    @Test func aRuntimeThatOffersNothingSaysSo() {
        #expect(resolve(name: "Cursor") == .nothingOffered(runtimeName: "Cursor"))
        #expect(resolve(agent: [], name: "Cursor") == .nothingOffered(runtimeName: "Cursor"))
    }

    /// A list of things we cannot draw is not a row.
    @Test func optionsThatCannotBeDrawnAreNotControls() {
        let unusable = [ConfigOption(id: "x", name: "X", category: "model", type: "colourwheel"),
                        ConfigOption(id: "y", name: "Y", category: "model", type: "select", options: [])]
        #expect(unusable.allSatisfy { !$0.isRenderable })
        #expect(resolve(draft: unusable) == .nothingOffered(runtimeName: "Claude"))
    }

    /// A fetch that threw told us nothing about what the runtime has.
    @Test func aFailedFetchIsNotAnEmptyRuntime() {
        #expect(resolve(failure: "The daemon is not answering.")
                == .failed(reason: "The daemon is not answering."))
    }

    /// One thing to do at a time, and the folder comes first.
    @Test func nothingIsChosenYet() {
        #expect(resolve(folder: false, runtime: false) == .needsFolder)
        #expect(resolve(folder: true, runtime: false) == .needsRuntime)
        // Neither outranks the other only because there is nothing to fetch yet.
        #expect(resolve(folder: false, loading: true) == .needsFolder)
    }

    /// The order the row is drawn in, and it does not wobble.
    @Test func controlsComeBackInCategoryOrder() {
        let scrambled = [select("thought", category: "thought_level"),
                         select("perms", category: "permissions"),
                         select("mode", category: "mode"),
                         select("model", category: "model")]
        guard case .controls(let ordered) = resolve(draft: scrambled) else {
            Issue.record("expected controls")
            return
        }
        #expect(ordered.map(\.id) == ["mode", "model", "thought", "perms"])
    }

    /// Two options a runtime did not categorise keep the order it sent them in, rather
    /// than swapping places between redraws.
    @Test func equalRanksKeepTheOrderTheRuntimeSentThem() {
        let unranked = [select("first", category: nil), select("second", category: nil)]
        guard case .controls(let ordered) = resolve(draft: unranked) else {
            Issue.record("expected controls")
            return
        }
        #expect(ordered.map(\.id) == ["first", "second"])
    }

    /// A runtime we were not told the name of still gets a sentence a person can read.
    @Test func anUnnamedRuntimeIsStillSaidOutLoud() {
        #expect(resolve(name: nil, loading: true)
                == .loading(runtimeName: PromptControlsState.unnamedRuntime))
        #expect(resolve(name: nil) == .nothingOffered(runtimeName: PromptControlsState.unnamedRuntime))
    }
}
