import Foundation

/// A walk's stand-in for a publicly trusted root (#61): one more CA that a Debug build
/// trusts for a control plane with no pin, so a certificate from a test CA such as Pebble
/// counts as public without touching this Mac's trust settings.
///
/// `AGENTS_TEST_TRUST_ROOT` holds the root as PEM, or as its DER in base64. Release builds
/// never read it, and Linux hosts use their system roots, where a walk installs the root.
public enum TestTrustRoot {
    /// The root's DER, when a Debug build is given one.
    public static var der: Data? {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["AGENTS_TEST_TRUST_ROOT"], !text.isEmpty else { return nil }
        return decode(text)
        #else
        return nil
        #endif
    }

    static func decode(_ text: String) -> Data? {
        let body = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: body)
    }
}
