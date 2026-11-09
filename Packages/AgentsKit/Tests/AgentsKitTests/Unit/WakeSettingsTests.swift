import Foundation
import Testing
@testable import AgentsKitCore

/// Sleep's runtime pickers (#4066): the hours are kept in range, and the footer says them
/// as the web page's `sleepFooter` does (`Web/test/sleep.test.mjs`).
@Suite("Wake settings")
struct WakeSettingsTests {
    @Test func backgroundHoursAreOneToTwentyFour() throws {
        #expect(WakeSettings(backgroundHours: 0).backgroundHours == 1)
        #expect(WakeSettings(backgroundHours: 30).backgroundHours == 24)
        let old = try JSONDecoder().decode(WakeSettings.self, from: Data(#"{"keepsAwake":true,"graceHours":1}"#.utf8))
        #expect(old.backgroundHours == 4)
    }

    @Test func theFooterSaysTheHoursAsTheWebDoes() {
        #expect(WakeWords.runtimesFooter(backgroundHours: 4)
            == "The sessions you are most likely to reply to keep their agent running for 10 minutes after their "
            + "turn ends, so the reply starts at once. An agent whose background processes still run (a dev server, "
            + "a build, a watcher) is kept for 4 hours, then ended with them. Neither keeps the Mac awake.")
        #expect(WakeWords.runtimesFooter(backgroundHours: 1).contains("kept for 1 hour, then"))
    }
}
