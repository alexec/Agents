// A daemon socket in a process of its own with few descriptors (#201), for
// `AcceptRecoveryTests`. Running out of descriptors is a property of the whole process,
// so a test cannot do it to a server beside every other test running at the same time.
//
//   accept-probe <socket path> <descriptor limit>
//
// Logs to <socket path>.log. Prints "ready" once the socket is listening, answers every call with {"ok": true},
// and stops when its standard input closes.
#if canImport(Darwin)
import AgentsKit
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let most = rlim_t(arguments[2]) else { exit(2) }
// As agentsd does, before anything can run out: the log's handle is open from the start.
DaemonLog.shared.setDestination(URL(fileURLWithPath: arguments[1] + ".log"))
DaemonLog.shared.write("accept-probe: listening with \(most) descriptors")
var limit = rlimit()
getrlimit(RLIMIT_NOFILE, &limit)
limit.rlim_cur = most
guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { exit(3) }

let server = DaemonServer(url: URL(fileURLWithPath: arguments[1])) { _, _, _ in .success(["ok": true]) }
do { try server.start() } catch { exit(4) }
print("ready")
fflush(stdout)
while readLine() != nil {}
server.stop()
#endif
