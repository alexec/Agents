import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent saying, at the end, how the work actually went.
///
/// The fourth tool on the app's own MCP server. These are the daemon's half: that the
/// tool is offered, that only the session it was minted for can report through it,
/// that a report moves the agent into the group its outcome names, and that a report
/// nobody can honour is refused in a sentence rather than a code.
@Suite("Reporting how it went", .timeLimit(.minutes(1)))
struct OutcomeReportTests {
}
