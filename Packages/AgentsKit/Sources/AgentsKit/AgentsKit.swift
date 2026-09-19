// AgentsKit is the Mac's half: the daemon, the stores, the runtimes it spawns and the
// terminal it runs them in. Everything both platforms share — the record, the line
// protocol, the daemon's method names and the client that speaks them — is in
// `AgentsKitCore`, which the phone links on its own.
//
// Re-exported rather than imported, so that the split is a fact about the package and
// not a line to add to eighty files. `import AgentsKit` still means all of it.
@_exported import AgentsKitCore
