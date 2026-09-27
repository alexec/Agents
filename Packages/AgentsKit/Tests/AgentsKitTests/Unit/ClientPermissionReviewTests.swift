import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Client permission review")
struct ClientPermissionReviewTests {
    private func sandbox() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ClientPermissionReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func options(allowOnce: Bool = true) -> [PermissionOption] {
        var list: [PermissionOption] = [
            .init(optionID: "allow_always", name: "Always", kind: .allowAlways),
            .init(optionID: "reject_once", name: "Deny", kind: .rejectOnce),
        ]
        if allowOnce {
            list.insert(.init(optionID: "allow_once", name: "Allow", kind: .allowOnce), at: 0)
        }
        return list
    }

    private func request(_ call: ToolCall, allowOnce: Bool = true) -> PermissionRequest {
        .init(agentID: UUID(), toolCall: call, options: options(allowOnce: allowOnce))
    }

    @Test func inReachEditIsAllowedOnce() throws {
        let root = try sandbox()
        let file = root.appending(path: "notes.txt")
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "Edit notes.txt", name: "write", kind: "edit",
                            locations: [.init(path: file.path)],
                            rawInput: .object(["file_path": .string(file.path), "content": .string("hi")]))
        let option = ClientPermissionReview.allowOnce(for: request(call), scope: scope)
        #expect(option?.kind == .allowOnce)
        #expect(option?.optionID == "allow_once")
    }

    @Test func cursorPathEditIsAllowed() throws {
        let root = try sandbox()
        let file = root.appending(path: "a.swift")
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "Editing a.swift", kind: "edit",
                            rawInput: .object(["path": .string(file.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope)?.kind == .allowOnce)
    }

    @Test func reachFolderEditIsAllowed() throws {
        let project = try sandbox()
        let reach = try sandbox()
        let file = reach.appending(path: "extra.txt")
        let scope = FolderScope(folders: [project, reach])
        let call = ToolCall(title: "Edit", name: "write", kind: "edit",
                            rawInput: .object(["file_path": .string(file.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope) != nil)
    }

    @Test func worktreeIsTheFolderThatCounts() throws {
        let original = try sandbox()
        let worktree = try sandbox()
        let file = worktree.appending(path: "changed.swift")
        let scope = FolderScope(folders: [worktree])
        let call = ToolCall(title: "Edit", kind: "edit",
                            locations: [.init(path: file.path)],
                            rawInput: .object(["path": .string(file.path)]))
        #expect(ClientPermissionReview.isOrdinary(call, scope: scope))
        #expect(!ClientPermissionReview.isOrdinary(call, scope: FolderScope(folders: [original])))
    }

    @Test func swiftTestIsAllowed() throws {
        let root = try sandbox()
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "swift test", name: "bash", kind: "execute",
                            rawInput: .object(["command": .string("swift test"),
                                               "working_directory": .string(root.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope) != nil)
    }

    @Test func localGitIsAllowedAndPushIsNot() throws {
        let root = try sandbox()
        let scope = FolderScope(folders: [root])
        let status = ToolCall(title: "git status", kind: "execute",
                              rawInput: .object(["command": .string("git status"),
                                                 "working_directory": .string(root.path)]))
        let push = ToolCall(title: "git push", kind: "execute",
                            rawInput: .object(["command": .string("git push origin main"),
                                               "working_directory": .string(root.path)]))
        #expect(ClientPermissionReview.isOrdinary(status, scope: scope))
        #expect(!ClientPermissionReview.isOrdinary(push, scope: scope))
    }

    @Test func outsidePathAsks() throws {
        let root = try sandbox()
        let elsewhere = try sandbox().appending(path: "secret.txt")
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "Edit", name: "write", kind: "edit",
                            rawInput: .object(["file_path": .string(elsewhere.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope) == nil)
    }

    @Test func symlinkEscapeAsks() throws {
        let root = try sandbox()
        let outside = try sandbox()
        let target = outside.appending(path: "target.txt")
        try "out".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "Edit", kind: "edit",
                            rawInput: .object(["path": .string(link.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope) == nil)
    }

    @Test func sudoAndMixedPathsAsk() throws {
        let root = try sandbox()
        let scope = FolderScope(folders: [root])
        let sudo = ToolCall(title: "sudo", kind: "execute",
                            rawInput: .object(["command": .string("sudo swift test"),
                                               "working_directory": .string(root.path)]))
        let mixed = ToolCall(title: "git add", kind: "execute",
                             rawInput: .object([
                                 "command": .string("git add /etc/passwd"),
                                 "working_directory": .string(root.path),
                             ]))
        let piped = ToolCall(title: "pipe", kind: "execute",
                             rawInput: .object(["command": .string("swift test | tee /tmp/out"),
                                                "working_directory": .string(root.path)]))
        #expect(!ClientPermissionReview.isOrdinary(sudo, scope: scope))
        #expect(!ClientPermissionReview.isOrdinary(mixed, scope: scope))
        #expect(!ClientPermissionReview.isOrdinary(piped, scope: scope))
    }

    @Test func unknownToolAndMissingAllowOnceAsk() throws {
        let root = try sandbox()
        let file = root.appending(path: "x.txt")
        let scope = FolderScope(folders: [root])
        let unknown = ToolCall(title: "Do a thing", name: "mystery_tool", kind: "edit",
                               rawInput: .object(["path": .string(file.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(unknown), scope: scope) == nil)

        let known = ToolCall(title: "Edit", kind: "edit",
                             rawInput: .object(["path": .string(file.path)]))
        #expect(ClientPermissionReview.allowOnce(for: request(known, allowOnce: false), scope: scope) == nil)
    }

    @Test func appControlToolsAsk() throws {
        let root = try sandbox()
        let scope = FolderScope(folders: [root])
        for name in [AppTool.startAgent, AppTool.manageWorkflows, AppTool.leaseResource,
                     AppTool.pushPullRequest] {
            let call = ToolCall(title: "agents_\(name)", name: "agents_\(name)", kind: "other")
            #expect(!ClientPermissionReview.isOrdinary(call, scope: scope), "\(name)")
            #expect(ClientPermissionReview.allowOnce(for: request(call), scope: scope) == nil, "\(name)")
        }
    }

    @Test func neverChoosesAllowAlways() throws {
        let root = try sandbox()
        let file = root.appending(path: "a.txt")
        let scope = FolderScope(folders: [root])
        let call = ToolCall(title: "Edit", kind: "edit",
                            rawInput: .object(["path": .string(file.path)]))
        let option = ClientPermissionReview.allowOnce(for: request(call), scope: scope)
        #expect(option?.kind == .allowOnce)
        #expect(option?.kind != .allowAlways)
    }
}
