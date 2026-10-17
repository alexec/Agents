The Linux `agentsd` binaries the app installs on a server (037) go here, built by
`scripts/build-linux-agentsd-go.sh`: the Go host (`agentsd-go-linux-<arch>`, the only one
since #1314) and the MCP servers beside it. They are build outputs and not in git. Without
them the app still builds and runs; only adding a Linux server fails, saying its system is
not supported.
