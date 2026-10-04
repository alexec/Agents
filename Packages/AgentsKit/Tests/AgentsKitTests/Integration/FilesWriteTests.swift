import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A file attached on the Mac, for an agent on a server (037).
@Suite("Writing an attachment")
struct FilesWriteTests {
    private func agent() async throws -> (DaemonCore, UUID, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWriteTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hi"))
        return (core, id, work)
    }

    private func write(_ core: DaemonCore, _ request: DaemonAPI.FilesWriteRequest) async -> Result<JSONValue, JSONRPCError> {
        await core.handle(method: DaemonAPI.Method.filesWrite, params: try? JSONValue.encoding(request))
    }

    @Test func theFileLandsInTheAgentsFolderWhole() async throws {
        let (core, id, work) = try await agent()
        let bytes = Data("hello from the Mac".utf8)
        let answer = try await write(core, .init(agentID: id, name: "notes.txt", data: bytes)).get()
            .decode(DaemonAPI.FilesWriteResponse.self)
        #expect(answer.path.hasPrefix(work.appendingPathComponent(".agents/attachments").path))
        #expect(answer.path.hasSuffix("-notes.txt"))
        #expect(try Data(contentsOf: URL(filePath: answer.path)) == bytes)
    }

    /// Attachments are kept a month, then go as the next one comes (#211).
    @Test func oldAttachmentsGoAsANewOneComes() async throws {
        let (core, id, work) = try await agent()
        let folder = work.appendingPathComponent(".agents/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("0000-old.png")
        let recent = folder.appendingPathComponent("0000-recent.png")
        for (file, age) in [(old, DiskSweep.attachmentAge + 86_400), (recent, 86_400)] {
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        let answer = try await write(core, .init(agentID: id, name: "new.txt", data: Data("y".utf8))).get()
            .decode(DaemonAPI.FilesWriteResponse.self)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: answer.path))
    }

    @Test func aNameCannotClimbOut() async throws {
        let (core, id, work) = try await agent()
        let answer = try await write(core, .init(agentID: id, name: "../../escape.txt", data: Data("x".utf8))).get()
            .decode(DaemonAPI.FilesWriteResponse.self)
        #expect(answer.path.hasPrefix(work.appendingPathComponent(".agents/attachments").path))
        #expect(answer.path.hasSuffix("-escape.txt"))
    }

    @Test func tooBigIsRefused() async throws {
        let (core, id, _) = try await agent()
        let big = Data(count: DaemonAPI.attachmentLimit + 1)
        guard case .failure = await write(core, .init(agentID: id, name: "big.bin", data: big)) else {
            Issue.record("a file over the limit was written"); return
        }
    }
}
