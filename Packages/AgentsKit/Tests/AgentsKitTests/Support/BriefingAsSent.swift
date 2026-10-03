import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

extension Briefing {
    /// The briefing a daemon with no person set sends a top-level agent on `runtimeID`:
    /// the runtime's text with who is who (#121), the person named from this account.
    static func asSent(to runtimeID: String) -> String {
        text(for: ToolPolicyCatalog.policy(for: runtimeID),
             naming: Naming(runtime: RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID,
                            person: PersonSettings().effectiveName()))
    }
}
