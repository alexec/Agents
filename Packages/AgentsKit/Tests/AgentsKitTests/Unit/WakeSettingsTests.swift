import Foundation
import Testing
@testable import AgentsKit

@Suite("Wake settings")
struct WakeSettingsTests {
    @Test("The default is on, for one hour, and hours outside 0...8 are clamped")
    func defaultsAndClamp() {
        #expect(WakeSettings() == WakeSettings(keepsAwake: true, graceHours: 1))
        #expect(WakeSettings(graceHours: -3).graceHours == 0)
        #expect(WakeSettings(graceHours: 9).graceHours == 8)
        #expect(WakeSettings(graceHours: 0).graceInterval == 0)
        #expect(WakeSettings(graceHours: 2).graceInterval == 7_200)
    }

    @Test("A missing file is the default, and a bad one is set aside")
    func store() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWakeSettings-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        let store = WakeSettingsStore(locations: locations)
        #expect(store.load() == WakeSettings())

        try store.save(WakeSettings(keepsAwake: false, graceHours: 4))
        #expect(store.load() == WakeSettings(keepsAwake: false, graceHours: 4))

        try Data("nope".utf8).write(to: locations.wakeSettings)
        #expect(store.load() == WakeSettings())
        #expect(FileManager.default.fileExists(atPath: locations.wakeSettings.path) == false)
    }

    @Test("The grace line names today, tomorrow, or the day")
    func untilLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 40))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15, minute: 40))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 1, minute: 10))!
        let laterDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!

        let today = WakeWords.untilLine(later, now: now, calendar: calendar)
        #expect(today.hasPrefix("Until "))
        #expect(!today.contains("tomorrow"))

        #expect(WakeWords.untilLine(tomorrow, now: now, calendar: calendar).contains("tomorrow"))
        let far = WakeWords.untilLine(laterDay, now: now, calendar: calendar)
        #expect(far.hasPrefix("Until "))
        #expect(!far.contains("tomorrow"))

        let help = WakeWords.graceHelp(later, now: now, calendar: calendar)
        #expect(help.hasPrefix("The last agent stopped. This Mac stays awake until "))
        #expect(help.hasSuffix(" so you can reply."))
    }
}
