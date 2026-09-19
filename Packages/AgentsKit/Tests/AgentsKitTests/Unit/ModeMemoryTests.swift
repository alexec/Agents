import Foundation
import Testing
@testable import AgentsKitCore

/// Remembering the mode, and knowing when not to.
@Suite("The mode you chose last time")
struct ModeMemoryTests {
    private func mode(_ id: String = "mode", category: String? = "mode",
                      values: [String] = ["default", "acceptEdits", "plan"],
                      current: String = "default") -> ConfigOption {
        ConfigOption(id: id, name: "Mode", category: category, type: "select",
                     currentValue: .string(current),
                     options: values.map { ConfigChoice(value: .string($0), name: $0) })
    }

    @Test func aRememberedModeTheRuntimeStillOffersIsUsed() {
        #expect(ModeMemory.startingValue(remembered: .string("plan"), for: mode())
                == .string("plan"))
    }

    /// The one that carries the feature. A mode the runtime has dropped must not be
    /// sent: an agent starting in a mode nobody chose is the worst thing this can do.
    @Test func aModeTheRuntimeHasDroppedIsDiscardedForItsOwnDefault() {
        #expect(ModeMemory.startingValue(remembered: .string("yolo"), for: mode())
                == .string("default"))
        // And with nothing current either, it is nothing rather than a guess.
        let noCurrent = ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                                     options: [ConfigChoice(value: .string("a"), name: "A")])
        #expect(ModeMemory.startingValue(remembered: .string("yolo"), for: noCurrent) == nil)
    }

    @Test func nothingRememberedLeavesTheRuntimesDefault() {
        #expect(ModeMemory.startingValue(remembered: nil, for: mode()) == .string("default"))
    }

    /// Copilot advertises a mode that is not called `mode`. The category is what the
    /// rest of the app keys on, so it is what this keys on too.
    @Test func theModeIsFoundByCategoryNotByName() {
        let found = ModeMemory.modeOption(in: [mode("permission_mode", category: "mode")])
        #expect(found?.id == "permission_mode")
    }

    /// Where both exist and disagree, the category wins.
    @Test func theCategoryBeatsTheName() {
        let byName = mode("mode", category: "model")
        let byCategory = mode("permission_mode", category: "mode")
        #expect(ModeMemory.modeOption(in: [byName, byCategory])?.id == "permission_mode")
    }

    @Test func aSwitchIsNeverTheMode() {
        let toggle = ConfigOption(id: "mode", name: "Fast", category: "mode", type: "boolean",
                                  currentValue: .bool(true))
        #expect(ModeMemory.modeOption(in: [toggle]) == nil)
    }

    /// Cursor's case. Nothing to remember is not a failure.
    @Test func aRuntimeWithNoModeOptionIsNotAFailure() {
        #expect(ModeMemory.modeOption(in: []) == nil)
        let model = ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                                 options: [ConfigChoice(value: .string("a"), name: "A")])
        #expect(ModeMemory.modeOption(in: [model]) == nil)
    }

    @Test func eachRuntimeRemembersItsOwn() {
        #expect(ModeMemory.defaultsKey(runtimeID: "claude") == "prompt.mode.claude")
        #expect(ModeMemory.defaultsKey(runtimeID: "copilot") == "prompt.mode.copilot")
        #expect(ModeMemory.defaultsKey(runtimeID: "claude") != ModeMemory.defaultsKey(runtimeID: "grok"))
    }
}
