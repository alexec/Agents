The Linux `agentsd` binaries the app installs on a server (037) go here, built by
`scripts/build-linux-agentsd.sh`: the Go host (`agentsd-go-linux-<arch>`, the default since
#1136) and the Swift one (`agentsd-linux-<arch>`, for `install.sh --impl swift`). They are build outputs and not in git. Without them the
app still builds and runs; only adding a Linux server fails, saying its system is not
supported.
