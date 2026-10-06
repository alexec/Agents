import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Nothing about a server the app's client connects to reaches the log: not its command,
/// arguments, environment, headers or URL (054 FR-023, #191 T046).
@Suite("MCP client logging", .timeLimit(.minutes(1)))
struct MCPClientLoggingTests {
    private let secret = "SENTINEL-71c3-client"

    @Test func aStdioServerDrivenThroughLeavesNoSentinel() async throws {
        // The command itself holds it: a folder named for it, with a script inside that
        // runs python3 (a link would not do: Xcode's python3 goes by the name it is called).
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(secret)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = folder.appending(path: "python3-\(secret)")
        try "#!/bin/sh\nexec python3 \"$@\"\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let lines = Lines()
        let server = MCPServer(name: "echo", transport: .stdio(
            command: command.path, args: [MCPClientTests.script, "--token=\(secret)"], env: ["KEY": secret]))
        let client = MCPClient(server: server, cwd: folder, timeout: .seconds(10), log: lines.add)
        try await client.connect()
        _ = try await client.listTools()
        _ = try? await client.readResource("ui://\(secret)")
        _ = try await client.callTool("echo", arguments: ["say": .string(secret)])
        await client.end()

        #expect(lines.all.contains("echo"), "it did log")
        #expect(!lines.all.contains(secret))
    }

    @Test func anHttpServerDrivenThroughLeavesNoSentinel() async throws {
        let lines = Lines()
        let standIn = StandIn()
        let server = MCPServer(name: "remote", transport: .http(
            url: "https://\(secret.lowercased()).example/mcp?k=\(secret)", headers: ["Authorization": "Bearer \(secret)"]))
        let client = MCPClient(server: server, cwd: FileManager.default.temporaryDirectory, log: lines.add, http: standIn.send)
        try await client.connect()
        _ = try await client.listTools()
        _ = try? await client.readResource("ui://\(secret)")
        _ = try? await client.callTool("x", arguments: ["say": .string(secret)])
        await client.end()

        // And one that fails, with the sentinel in what came back.
        let locked = MCPClient(server: server, cwd: FileManager.default.temporaryDirectory, log: lines.add,
                               http: StandIn(unauthorized: "Bearer resource_metadata=\"https://\(secret)/\"").send)
        _ = try? await locked.connect()

        #expect(lines.all.contains("remote"), "it did log")
        #expect(!lines.all.lowercased().contains(secret.lowercased()))
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: String { lock.withLock { lines.joined(separator: "\n") } }
    var add: @Sendable (String) -> Void { { [self] line in lock.withLock { lines.append(line) } } }
}
