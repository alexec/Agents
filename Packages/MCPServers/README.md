# MCP servers

The MCP servers Agents ships (#700). Each is a single static binary in Swift, so a host that
runs one, a Mac or a Linux machine in the cloud, needs no Node or other runtime. The workspace
command provider ([#691](../../specs/691-workspace-providers/spec.md)) is the one here now. The
CI watcher was the first; the github server in Go (`Go/cmd/github-mcp`, #1232) took its place
(#1231).

| Target | What it is |
| --- | --- |
| `MCPServerKit` | What every server here shares: a `JSON` value, JSON-RPC over one line, MCP's stdio transport, `MCPServer` (`initialize`, `ping`, and the lists and calls of tools, resources and events), `Schema` for arguments, `EventPoll` and `PollCursor` for `events/poll`, and `ChildProcess` for running a command such as `gh`. |
| `WorkspaceCommands` | The command provider: a workspace provider whose workspaces are shell commands, with presets for `docker`, `doctl`, `gh codespace`, `coder` and `gcloud workstations` ([contract](../../specs/691-workspace-providers/contracts/command-provider.md)). |
| `workspace-commands` | Its binary. |

Nothing here depends on AgentsKit, so a server stays small and builds for Linux on its own.

## A new server

An executable target that depends on `MCPServerKit`, whose `main.swift` builds an `MCPServer`
and serves it:

```swift
let server = MCPServer(
    info: .init(name: "example", title: "Example", version: "0.1.0"),
    instructions: "What it is for, for the model.",
    tools: [Tool(name: "hello", title: "Say hello", description: "…", inputSchema: Schema(["name": .string("Who")]))],
    callTool: { tool, arguments in
        let args = try tool.inputSchema.check(arguments)
        return ToolResult.text("hello \(args["name"]?.string ?? "you")")
    })
await StdioTransport.serve(server, name: "example")
```

A view (an MCP app) is a `Resource` whose text is carried in the binary: a resource bundle
beside it would make it more than one file.

## The command provider

A workspace provider (#691): the control plane starts and stops the machines hosts run on
through it. It follows the [provider contract](../../specs/691-workspace-providers/contracts/provider-contract.md)
(`workspaces_list`, `workspace_start`, `workspace_stop`), and its whole configuration is the
JSON in `WORKSPACE_COMMANDS_CONFIG`: workspaces written out, one list command, or a preset.

```sh
WORKSPACE_COMMANDS_CONFIG='{"preset":"docker","containers":["agents-devbox"],"ssh":"alex@127.0.0.1 -p 2222"}' \
    swift run --package-path Packages/MCPServers workspace-commands
```

Commands run with `/bin/sh -c`, each value filled in as one quoted word. A start or stop answers
once the workspace's status (or the list) says it is running or stopped, and fails with the
command's own last lines of stderr. Secrets come in as environment variables, which the
commands inherit. Nothing is written to disk.

## Building for Linux

The same static musl build as `agentsd`, with the swift.org toolchain and its Static Linux SDK
([quickstart](../../specs/037-cloud-agents/quickstart.md)):

```sh
swift build --package-path Packages/MCPServers -c release \
    --swift-sdk aarch64-swift-linux-musl --product workspace-commands -Xswiftc -gnone -Xlinker -s
```

## Tests

```sh
scripts/build-cache.sh swift test --package-path Packages/MCPServers
```

CI runs them on Linux (`mcp-servers` in `.github/workflows/ci.yml`) whenever this package
changes.
