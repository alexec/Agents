import Foundation
import Testing
@testable import AgentsKitCore

/// Agents Host keeps only the newest 2 stores and control plane keys set aside (#3671).
@Suite("Stores set aside")
struct StoresAsideTests {
    /// The name `prepareReturn` gives a store set aside on a move back.
    private func returnName(_ seconds: Int) -> String {
        let day = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601.year().month().day())
        return "store-before-\(day)-\(seconds % 100_000)"
    }

    @Test func eachNameGivesTheTimeItWasSetAside() {
        #expect(StoresAside.time(of: "store-before-1793000123") == Date(timeIntervalSince1970: 1_793_000_123))
        #expect(StoresAside.time(of: "control-key-before-1793000123") == Date(timeIntervalSince1970: 1_793_000_123))
        for seconds in [1_793_000_123, 1_793_059_999, 1_793_060_000, 1_792_972_800, 1_793_059_199] {
            #expect(StoresAside.time(of: returnName(seconds)) == Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        #expect(StoresAside.time(of: "store") == nil)
        #expect(StoresAside.time(of: "store-before-notes") == nil)
        #expect(StoresAside.time(of: "control-key") == nil)
    }

    @Test func onlyTheNewestTwoStayAndOtherNamesAreLeftAlone() {
        let names = ["store-before-1000", returnName(1_793_000_123), "store-before-3000", "store-before-x",
                     "store-before-1793100000"]
        #expect(StoresAside.beyond(names) == ["store-before-1000", "store-before-3000"])
        #expect(StoresAside.beyond(["control-key-before-5", "control-key-before-9"]).isEmpty)
        #expect(StoresAside.beyond(["control-key-before-5", "control-key-before-9", "control-key-before-7"])
            == ["control-key-before-5"])
    }

    @Test func pruningAScratchHomeDeletesOnlyTheOldStores() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("stores-aside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let names = ["store-before-100", "store-before-200", returnName(1_793_000_123), "store-before-300", "store"]
        for name in names {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("key".utf8).write(to: home.appendingPathComponent("control-key-before-100"))

        #expect(StoresAside.pruneFolders(in: home) == ["store-before-100", "store-before-200"])
        let left = try FileManager.default.contentsOfDirectory(atPath: home.path).sorted()
        #expect(left == ["control-key-before-100", "store", returnName(1_793_000_123), "store-before-300"].sorted())
    }
}
