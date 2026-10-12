// The command provider (#691), one static binary on stdio. Its configuration is the JSON in
// WORKSPACE_COMMANDS_CONFIG (specs/691-workspace-providers/contracts/command-provider.md);
// any secret its commands use comes in as another environment variable.
import Foundation
import MCPServerKit
import WorkspaceCommands

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("workspace-commands \(WorkspaceCommands.version)")
    exit(0)
}

let config: CommandConfig
do {
    config = try CommandConfig.parse(ProcessInfo.processInfo.environment["WORKSPACE_COMMANDS_CONFIG"] ?? "")
} catch {
    log("workspace-commands: \(error)")
    exit(2)
}
log("workspace-commands \(WorkspaceCommands.version) on stdio")
await StdioTransport.serve(WorkspaceCommands.server(config), name: "workspace-commands")
