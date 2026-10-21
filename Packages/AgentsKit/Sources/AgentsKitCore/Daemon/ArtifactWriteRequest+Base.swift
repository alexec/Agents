import CryptoKit
import Foundation

public extension DaemonAPI.ArtifactWriteRequest {
    /// A text's `base` (#1858): its SHA-256 in lower-case hex, as the host works it out.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
