# MCP servers

The MCP servers Agents ships (#700). Each is a single static binary in Swift, so a host that
runs one, a Mac or a Linux machine in the cloud, needs no Node or other runtime. The CI
watcher is the first; the workspace command provider ([#691](../../specs/691-workspace-providers/spec.md))
is next.

| Target | What it is |
| --- | --- |
| `MCPServerKit` | What every server here shares: a `JSON` value, JSON-RPC over one line, MCP's stdio transport, `MCPServer` (`initialize`, `ping`, and the lists and calls of tools, resources and events), `Schema` for arguments, `EventPoll` and `PollCursor` for `events/poll`, and `ChildProcess` for running a command such as `gh`. |
| `CIWatcher` | The CI watcher: this repo's pull requests' CI and its issues as events, tools and views ([contract](../../specs/383-mcp-integrations/contracts/ci-watcher-server.md)). `RealGitHub` calls `gh` as the signed-in person; `FakeGitHub` reads and writes a JSON file. |
| `ci-watcher` | Its binary. |

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

A view (an MCP app) is a `Resource` whose text is carried in the binary, as the CI watcher's
`Views.swift` does: a resource bundle beside it would make it more than one file.

## The CI watcher

Its events, tools and views are listed in the
[contract](../../specs/383-mcp-integrations/contracts/ci-watcher-server.md). It needs a
signed-in `gh` on PATH (`gh auth status`): every GitHub call is `gh api` or `gh pr list` as
you, so the server holds no token. Without it, tools answer with an error and `events/poll`
answers `-32012` (`gh not signed in`). A `repo` left out is the one the server's folder pushes
to, as `gh repo view` names it.

It speaks newline-delimited JSON-RPC on stdin and stdout, and logs to stderr:

```sh
swift run --package-path Packages/MCPServers ci-watcher
```

### The fake mode

```sh
CI_WATCHER_FAKE=Packages/MCPServers/Tests/CIWatcherTests/Fixtures/ci.json swift run --package-path Packages/MCPServers ci-watcher
```

With `CI_WATCHER_FAKE` set, nothing calls `gh` or GitHub: pull requests, runs and job logs are
read from the JSON file on every call, and reruns and comments are written back to it
(`reruns`, `comments`). Append a failed run to `runs` with a fresh `updatedAt`, and the next
poll raises it. Issues are under `issues`, each with its `comments` and `events` (`labeled` or
`closed`); append one, or a comment or event with a fresh `createdAt`, and the next poll
raises it. An issue, comment or PR raises an event only with an `authorAssociation` of
`OWNER`, `MEMBER` or `COLLABORATOR` and an `author` not ending `[bot]` (#728), unless the
poll asks for `anyone`. Set `"gh": "notSignedIn"`, or `"gh": {"rateLimitedForMs": 60000}`, to see the
errors. Copy the fixture before writing to it; the tests start from it.

## Building for Linux

The same static musl build as `agentsd`, with the swift.org toolchain and its Static Linux SDK
([quickstart](../../specs/037-cloud-agents/quickstart.md)):

```sh
swift build --package-path Packages/MCPServers -c release \
    --swift-sdk aarch64-swift-linux-musl --product ci-watcher -Xswiftc -gnone -Xlinker -s
```

## Tests

```sh
scripts/build-cache.sh swift test --package-path Packages/MCPServers
```

CI runs them on Linux (`mcp-servers` in `.github/workflows/ci.yml`) whenever this package
changes. The CI watcher's run its fake mode in process, each against its own copy of the
fixture.
