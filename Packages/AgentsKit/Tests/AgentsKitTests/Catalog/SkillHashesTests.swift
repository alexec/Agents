#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

/// The three hashes, against values made by `git` and by the `skills` CLI's own function run
/// under `node` (059, tasks T007; `Fixtures/catalog/golden.json`).
@Suite("Skill hashes")
struct SkillHashesTests {
    static let fixtures = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/catalog")

    struct Golden: Decodable {
        struct Blob: Decodable { var mode: String; var sha: String }
        struct Fixture: Decodable {
            var computedHash: String
            var localeOrder: [String]
            var treeSHA: String
            var blobs: [String: Blob]
        }
        var fixtures: [String: Fixture]
    }

    static func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixtures.appending(path: "golden.json")))
    }

    /// A copy outside the repository, so the executable bit on `scripts/lint.sh` is what git
    /// checked out rather than whatever the build copied.
    static func skill(_ name: String) -> URL { fixtures.appending(path: "skills/\(name)") }

    @Test(arguments: ["plain", "mixed", "nested"])
    func computedHashIsTheCLIs(_ name: String) throws {
        let golden = try #require(try Self.golden().fixtures[name])
        #expect(try SkillHashes.computedHash(folder: Self.skill(name)) == golden.computedHash)
    }

    @Test(arguments: ["plain", "mixed", "nested"])
    func treeSHAIsGits(_ name: String) throws {
        let golden = try #require(try Self.golden().fixtures[name])
        #expect(try SkillHashes.treeSHA(folder: Self.skill(name)) == golden.treeSHA)
    }

    @Test(arguments: ["plain", "mixed", "nested"])
    func blobSHAIsGits(_ name: String) throws {
        let golden = try #require(try Self.golden().fixtures[name])
        for (path, blob) in golden.blobs {
            let data = try Data(contentsOf: Self.skill(name).appending(path: path))
            #expect(SkillHashes.blobSHA(data) == blob.sha, "\(name)/\(path)")
        }
    }

    @Test(arguments: ["plain", "mixed", "nested"])
    func localeOrderIsNodes(_ name: String) throws {
        let golden = try #require(try Self.golden().fixtures[name])
        #expect(golden.localeOrder.shuffled().sorted(by: SkillHashes.localeLess) == golden.localeOrder)
    }

    /// The two orders really differ on `mixed/`, so a byte-order comparator could not pass
    /// the test above by luck.
    @Test func theOrdersDifferOnMixed() throws {
        let golden = try #require(try Self.golden().fixtures["mixed"])
        #expect(golden.localeOrder.sorted() != golden.localeOrder)
    }

    @Test func inMemoryMatchesOnDisk() throws {
        let folder = Self.skill("nested")
        let golden = try #require(try Self.golden().fixtures["nested"])
        let files = try golden.blobs.keys.map { ($0, try Data(contentsOf: folder.appending(path: $0))) }
        #expect(SkillHashes.computedHash(files: files) == golden.computedHash)
    }
}
#endif
