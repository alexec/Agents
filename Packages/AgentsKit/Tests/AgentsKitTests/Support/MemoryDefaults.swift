import Foundation
import Testing

/// A `UserDefaults` that is only in memory, for a test that needs a defaults store of its
/// own (#1028).
///
/// `UserDefaults(suiteName:)` is a plist in `~/Library/Preferences`, and
/// `removePersistentDomain(forName:)` empties it but leaves the file: cfprefsd writes it
/// back even after the test deletes it. A suite per test left 11,028 domains on one Mac.
/// This one writes nothing to disk, so there is nothing to remove.
///
/// The typed getters (`data(forKey:)`, `stringArray(forKey:)`, …) read through
/// `object(forKey:)`, and the typed setters write through `set(_:forKey:)`, so these four
/// are all a store sees.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { _ = values.removeValue(forKey: defaultName) }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }
}

@Suite("Memory defaults")
struct MemoryDefaultsTests {
    @Test func keepsWhatIsSetAndNothingElse() {
        let defaults = MemoryDefaults()
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.set(["a", "b"], forKey: "strings")
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.stringArray(forKey: "strings") == ["a", "b"])
        #expect(Set(defaults.dictionaryRepresentation().keys) == ["data", "strings"],
                "nothing from the app's own domains")
        defaults.removeObject(forKey: "data")
        #expect(defaults.data(forKey: "data") == nil)
        #expect(MemoryDefaults().stringArray(forKey: "strings") == nil, "each is its own")
    }

    /// No test makes an on-disk suite: each one is a plist that outlives the run.
    @Test func noTestMakesADefaultsSuiteOnDisk() throws {
        let tests = URL(filePath: #filePath)
            .deletingLastPathComponent()      // Support
            .deletingLastPathComponent()      // AgentsKitTests
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let offenders = files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "MemoryDefaults.swift" }
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("UserDefaults(suiteName:") == true }
            .map(\.lastPathComponent)
        #expect(offenders.isEmpty, "use MemoryDefaults()")
    }
}
