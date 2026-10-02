#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
import AgentsKitCore

@Suite("MCP catalogue methods are a person's")
struct MCPCatalogControlTests {
    @Test func notAnAgentsOrAStrangers() {
        for method in DaemonAPI.Method.mcpCatalogMethods {
            #expect(ConnectionRole.control.allows(method))
            #expect(ConnectionRole.device.allows(method))
            #expect(!ConnectionRole.agent.allows(method))
            #expect(!ConnectionRole.stranger.allows(method))
        }
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.catalogSearch))
    }
}
#endif
