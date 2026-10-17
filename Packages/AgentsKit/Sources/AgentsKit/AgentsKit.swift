// AgentsKit is the Mac's half that Agents Host and agents-relay still link: the relay's
// dial to the control plane, the move of a set-up, ssh, and the local socket's server and
// lock. The daemon itself is Go (#1138); its Swift sources went in #1314. Everything both
// platforms share (the record, the line protocol, the daemon's method names and the client
// that speaks them) is in `AgentsKitCore`, which the phone links on its own.
//
// Re-exported rather than imported, so that `import AgentsKit` still means all of it.
@_exported import AgentsKitCore
