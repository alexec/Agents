// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// Which way the device is reaching the Mac right now (046, data-model.md § Link).
public enum RemoteLink: Sendable, Hashable {
    case direct
    case relayed
    case none
}
#endif
