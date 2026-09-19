// AgentsKitCore is what an iPhone can hold: the record, the JSON-RPC line protocol,
// the daemon's method names and DTOs, and the client that speaks them over whatever
// transport it is handed — a Unix socket on the Mac, a mailbox from a train.
//
// Nothing here spawns a process, opens a PTY or takes a lock. That is the rule that
// keeps the target honest, and the compiler enforces it every time the phone builds.
