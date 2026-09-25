import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the Mac has that can be leased, and what a name an agent gives comes to (036 US6).
@Suite("The resource catalog")
struct ResourceCatalogTests {
    /// The shape `xcrun simctl list devices available -j` prints, cut down.
    private let listing = Data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17 Pro", "udid": "AAAA-1111", "isAvailable": true, "state": "Shutdown"},
            {"name": "iPad Pro 13-inch (M5)", "udid": "BBBB-2222", "isAvailable": true, "state": "Booted"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"name": "iPhone 17 Pro", "udid": "CCCC-3333", "isAvailable": true},
            {"name": "Twin", "udid": "DDDD-4444", "isAvailable": true},
            {"name": "Broken", "udid": "EEEE-5555", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
            {"name": "Twin", "udid": "FFFF-6666", "isAvailable": true}
          ]
        }}
        """.utf8)

    @Test func simulatorsAreKeyedByTheirUDIDAndNamedWithTheirSystem() {
        let found = ResourceCatalog.simulators(from: listing)
        #expect(found.map(\.displayName) == ["iPad Pro 13-inch (M5) · iOS 26.0", "iPhone 17 Pro · iOS 26.0",
                                             "iPhone 17 Pro · iOS 27.0", "Twin · iOS 27.0",
                                             "Twin · watchOS 12.0"])
        #expect(found.allSatisfy { $0.kind == .simulator })
        #expect(found.contains { $0.name == ResourceName("simulator:aaaa-1111") })
        #expect(!found.contains { $0.displayName.hasPrefix("Broken") }, "unavailable devices are left out")
    }

    @Test func aRuntimeIdentifierReadsAsASystemName() {
        #expect(ResourceCatalog.systemName("com.apple.CoreSimulator.SimRuntime.iOS-26-0") == "iOS 26.0")
        #expect(ResourceCatalog.systemName("com.apple.CoreSimulator.SimRuntime.xrOS-3-1") == "xrOS 3.1")
        #expect(ResourceCatalog.systemName("nonsense") == nil)
    }

    @Test func somethingThatIsNotAListingIsNoSimulators() {
        #expect(ResourceCatalog.simulators(from: Data("xcrun: error".utf8)).isEmpty)
        #expect(ResourceCatalog.simulators(from: Data()).isEmpty)
    }

    private var catalog: FixedCatalog {
        FixedCatalog([.screen] + ResourceCatalog.simulators(from: listing)
                     + [FoundResource(name: ResourceName("browser:com.apple.safari")!, kind: .browser,
                                      displayName: "Safari", aliases: ["Safari"])])
    }

    @Test func aNameResolvesByKeyUDIDOrDisplayName() async {
        #expect(await catalog.resolve("Screen")?.name == .screen)
        #expect(await catalog.resolve("aaaa-1111")?.name == ResourceName("simulator:aaaa-1111"))
        #expect(await catalog.resolve("SIMULATOR:AAAA-1111")?.name == ResourceName("simulator:aaaa-1111"))
        #expect(await catalog.resolve("iPhone 17 Pro · iOS 27.0")?.name == ResourceName("simulator:cccc-3333"))
        #expect(await catalog.resolve("safari")?.kind == .browser)
    }

    @Test func aNameTwoDevicesShareResolvesToNeitherButToItself() async {
        // Only unique aliases resolve; this display name is one device's, not two.
        let ambiguous = FixedCatalog(catalog.list + [FoundResource(
            name: ResourceName("simulator:zzzz")!, kind: .simulator,
            displayName: "iPhone 17 Pro · iOS 27.0", aliases: ["iPhone 17 Pro · iOS 27.0"])])
        let resolved = await ambiguous.resolve("iPhone 17 Pro · iOS 27.0")
        #expect(resolved?.kind == .named)
    }

    @Test func aNameTheCatalogDoesNotKnowIsTheAgentsOwn() async {
        let resolved = await catalog.resolve("  Port 8080 ")
        #expect(resolved?.kind == .named)
        #expect(resolved?.displayName == "Port 8080")
        #expect(resolved?.name == ResourceName("port 8080"))
        #expect(await catalog.resolve("   ") == nil)
    }
}
