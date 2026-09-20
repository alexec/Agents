import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A turn that ended and said nothing about itself.
///
/// The app asks once, and never again — the bound is what these tests are for. An
/// ending nobody accounted for is not a completion, and an agent that will not answer
/// must not be able to make the asking cost more than the turns themselves.
@Suite("An ending nobody accounted for", .timeLimit(.minutes(1)))
struct UnreportedEndingTests {
}
