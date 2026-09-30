import AgentsKitCore
import Foundation

/// A runtime with nothing behind it (058, T092): `agentsd acp-echo`, speaking ACP on its
/// standard input and output and answering every prompt by saying it back.
///
/// For the demo control plane App Review is given, and nothing else: it signs in to
/// nobody, reads and writes no file and runs no command, so a reviewer can start an agent,
/// send it a prompt and see the answer on any host without an account of their own. It is
/// offered only when the host was started with `AGENTS_TEST_RUNTIME=echo`.
public enum EchoAgent {
    public static let variable = "AGENTS_TEST_RUNTIME"

    /// The demo runtime, when this host was told to offer it; its command is this binary.
    public static var runtime: Runtime? {
        guard ProcessInfo.processInfo.environment[variable] == "echo" else { return nil }
        let me = URL(filePath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        return Runtime(id: "demo", name: "Demo", executable: me, arguments: ["acp-echo"])
    }

    /// Serve one runtime connection on stdin and stdout until the daemon closes it.
    public static func run() async {
        let transport = FDTransport(readFD: FileHandle.standardInput.fileDescriptor,
                                    writeFD: FileHandle.standardOutput.fileDescriptor)
        let session = UUID().uuidString.lowercased()
        let replies = Replies()
        let connection = JSONRPCConnection(transport: transport) { method, params in
            await replies.handle(method: method, params: params, session: session)
        }
        await replies.attach(connection)
        await connection.start()
        for await _ in connection.incomingNotifications() {}
    }

    actor Replies {
        private var connection: JSONRPCConnection?

        func attach(_ connection: JSONRPCConnection) { self.connection = connection }

        func handle(method: String, params: JSONValue?, session: String) async -> Result<JSONValue, JSONRPCError> {
            switch method {
            case "initialize":
                return .success([
                    "protocolVersion": 1,
                    "agentCapabilities": ["loadSession": false, "promptCapabilities": ["image": false]],
                    "agentInfo": ["name": "Demo", "version": "1.0"],
                    "authMethods": [],
                ])
            case "session/new":
                return .success(["sessionId": .string(session)])
            case "session/prompt":
                // What the person typed: the first text block's first paragraph. The rest is
                // the host's own briefing, which is not theirs to be told back.
                let first = (params?["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.first ?? ""
                let said = first.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
                let answer = said.isEmpty ? "(nothing to say back)" : "You said: \(said)"
                try? connection?.notify("session/update", [
                    "sessionId": .string(session),
                    "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(answer)]],
                ])
                return .success(["stopReason": "end_turn"])
            case "session/cancel":
                return .success([:])
            default:
                return .failure(JSONRPCError.methodNotFound(method))
            }
        }
    }
}
