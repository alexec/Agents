import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the app promises a runtime in `initialize` (052 adds typed failures).
@Suite("What the app offers in the handshake")
struct ClientCapabilitiesTests {
    @Test func typedFailuresAreAskedFor() {
        let wire = ACP.ClientCapabilities.app.wire
        #expect(wire["_meta"]?["jetbrains"]?["air"]?["version"] == .int(1))
        // One AIR list for everything asked for: 057's background tasks and subagents too.
        #expect(wire["_meta"]?["jetbrains"]?["air"]?["capabilities"]
                == ["asyncTasks", "nativeSubagentSessions", "sessionFailure"])
    }

    @Test func everythingOfferedBeforeIsStillOffered() {
        let wire = ACP.ClientCapabilities.app.wire
        for key in ["fs", "terminal", "session", "plan", "auth", "elicitation"] {
            #expect(wire[key] != nil, "\(key) is still offered")
        }
    }

    /// A client that has not built the reading of typed failures must not ask for them:
    /// the adapters then end a refused turn as `end_turn`, which would read as done.
    @Test func nothingIsAskedForByDefault() {
        #expect(ACP.ClientCapabilities.none.wire["_meta"] == nil)
    }
}
