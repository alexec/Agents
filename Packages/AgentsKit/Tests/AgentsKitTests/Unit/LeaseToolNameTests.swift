import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Which lease call a tool name is (036). "release_resource" ends with
/// "lease_resource", and matching on the end of a name — which a runtime's prefix
/// makes necessary — once turned every release into an extension.
@Suite("Lease tool names")
struct LeaseToolNameTests {
    private let arguments: JSONValue = ["name": "screen", "minutes": 20, "wait": false]

    private func call(_ name: String) -> AppService.LeaseCall? {
        guard case .success(let call)? = AppService.leaseCall(named: name, arguments) else { return nil }
        return call
    }

    @Test(arguments: ["", "mcp__agents__"])
    func eachNameIsItsOwnCall(prefix: String) {
        #expect(call(prefix + "release_resource") == .release(name: "screen"))
        #expect(call(prefix + "lease_resource") == .lease(name: "screen", minutes: 20, wait: false))
        #expect(call(prefix + "list_resources") == .list)
    }

    @Test func otherToolsAreNotLeaseCalls() {
        #expect(AppService.leaseCall(named: "mcp__agents__finish_turn", arguments) == nil)
        #expect(AppService.leaseCall(named: "mcp__agents__start_agent", arguments) == nil)
    }
}
