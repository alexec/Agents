import Foundation
import Testing
@testable import AgentsKitCore

/// The phone's New session ready at once (#1171): drawn from what the runtime offered last
/// time, then put right by the draft's answer, with the choices still offered kept.
@Suite("The New session page's remembered choices")
struct StartChoicesMemoryTests {
    private static func model(_ values: [String], current: String) -> ConfigOption {
        ConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string(current),
                     options: values.map { ConfigChoice(value: .string($0), name: $0) })
    }

    private static func mode(_ values: [String], current: String) -> ConfigOption {
        ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select", currentValue: .string(current),
                     options: values.map { ConfigChoice(value: .string($0), name: $0) })
    }

    @Test func oneListForEachRuntimeOnEachHost() {
        var memory = StartChoicesMemory()
        let server = MachineRef(rawValue: "server-1")
        #expect(memory.options(for: "claude", on: .mac) == nil)

        memory.remember([Self.model(["opus"], current: "opus")], for: "claude", on: .mac)
        memory.remember([Self.model(["sonnet"], current: "sonnet")], for: "claude", on: server)
        memory.remember([Self.model(["opus", "fable"], current: "fable")], for: "claude", on: .mac)

        #expect(memory.count == 2)
        #expect(memory.options(for: "claude", on: .mac)?.first?.options?.count == 2)
        #expect(memory.options(for: "claude", on: server)?.first?.currentValue == .string("sonnet"))
        #expect(memory.options(for: "codex", on: .mac) == nil)
    }

    @Test func aReplyThatChangesTheOptionsKeepsTheValidChoices() {
        var memory = StartChoicesMemory()
        memory.remember([Self.model(["opus", "sonnet"], current: "opus"), Self.mode(["default", "plan"], current: "default")],
                        for: "claude", on: .mac)

        // Drawn from memory, with the person's last choices.
        let remembered = memory.options(for: "claude", on: .mac) ?? []
        let opened = StartChoicesMemory.kept(["model": .string("sonnet"), "mode": .string("plan")], in: remembered)
        #expect(opened == ["model": .string("sonnet"), "mode": .string("plan")])

        // The draft answers: sonnet is gone, plan is still there, and effort is new.
        let effort = ConfigOption(id: "effort", name: "Effort", type: "select", currentValue: .string("high"),
                                  options: [ConfigChoice(value: .string("high"), name: "High")])
        let answered = [Self.model(["opus", "fable"], current: "opus"), Self.mode(["default", "plan"], current: "default"), effort]
        memory.remember(answered, for: "claude", on: .mac)
        let corrected = StartChoicesMemory.kept(opened, in: answered)

        #expect(corrected == ["model": .string("opus"), "mode": .string("plan"), "effort": .string("high")])
        #expect(memory.options(for: "claude", on: .mac) == answered)
    }

    @Test func aSwitchKeepsItsChoiceAndAnOptionGoneIsLetGo() {
        let fast = ConfigOption(id: "fast", name: "Fast", type: "boolean", currentValue: .bool(false))
        let kept = StartChoicesMemory.kept(["fast": .bool(true), "gone": .string("x")], in: [fast])
        #expect(kept == ["fast": .bool(true)])
    }
}
