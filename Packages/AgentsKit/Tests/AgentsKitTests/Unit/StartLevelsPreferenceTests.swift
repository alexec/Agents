import Testing
@testable import AgentsKitCore

/// The levels last chosen on a start form are the next session's, on every client (#3798).
@Suite struct StartLevelsPreferenceTests {
    @Test func nothingKeptIsBalancedAndAsk() {
        #expect(DisplayPreference.keptLevels(in: [:]) == Levels(model: .balanced, permission: .ask))
    }

    @Test func keptLevelsComeBack() {
        let change = DisplayPreference.keeping(Levels(model: .smart, permission: .bypassPermissions), in: [:])
        #expect(change == [DisplayPreference.startLevels: .object(["model": .string("smart"),
                                                                 "permission": .string("bypassPermissions")])])
        #expect(DisplayPreference.keptLevels(in: change) == Levels(model: .smart, permission: .bypassPermissions))
        #expect(DisplayPreference.keeping(Levels(model: .smart, permission: .bypassPermissions), in: change).isEmpty)
    }

    @Test func aLevelNotKnownIsTheDefaults() {
        let said: DaemonAPI.DisplayPreferences = [DisplayPreference.startLevels: .object(["model": .string("huge"),
                                                                                        "permission": .string("approveForMe")])]
        #expect(DisplayPreference.keptLevels(in: said) == Levels(model: .balanced, permission: .approveForMe))
    }
}
