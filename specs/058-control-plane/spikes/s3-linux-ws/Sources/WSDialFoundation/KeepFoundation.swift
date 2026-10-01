import Foundation
// The same dialer with Foundation linked, to measure what NIO + NIOSSL add to agentsd,
// which already links Foundation.
let keepFoundation = try! JSONSerialization.data(withJSONObject: ["at": Date().description])
