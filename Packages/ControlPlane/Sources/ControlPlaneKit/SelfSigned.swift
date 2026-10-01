import ControlDial
import Foundation
import NIOSSL

/// A self-signed certificate for a copy that terminates TLS itself: Agents Host's single
/// copy, or a walk (058, R6). Clients accept it by its pin, never by its name, so the name
/// on it does not matter. Made once with `openssl` and kept in `dir`.
public enum SelfSigned {
    public static func make(in dir: URL, name: String) throws -> (NIOSSLContext, pin: String) {
        let cert = dir.appendingPathComponent("cert.pem")
        let key = dir.appendingPathComponent("key.pem")
        if !FileManager.default.fileExists(atPath: cert.path) || !FileManager.default.fileExists(atPath: key.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let openssl = ["/usr/bin/openssl", "/usr/local/bin/openssl", "/opt/homebrew/bin/openssl"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let openssl else {
                throw ControlService.Failure("making a certificate needs openssl; give AGENTS_CONTROL_TLS_CERT and _KEY instead")
            }
            // Two steps, and a named curve: LibreSSL's one-step `req -newkey ec` writes the
            // curve's parameters out in full, and BoringSSL refuses such a key.
            try run(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
            chmod(key.path, 0o600)
            try run(openssl, ["req", "-new", "-x509", "-key", key.path, "-out", cert.path, "-days", "3650",
                              "-subj", "/CN=\(name)"])
        }
        return try load(cert: cert, key: key)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ControlService.Failure("openssl could not make a certificate") }
    }

    /// A certificate and key from files, as a server context, and the certificate's pin.
    public static func load(cert: URL, key: URL) throws -> (NIOSSLContext, pin: String) {
        let chain = try NIOSSLCertificate.fromPEMFile(cert.path)
        guard let leaf = chain.first else { throw ControlService.Failure("\(cert.path) has no certificate") }
        let privateKey = try NIOSSLPrivateKey(file: key.path, format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: chain.map { .certificate($0) },
                                                           privateKey: .privateKey(privateKey))
        tls.minimumTLSVersion = .tlsv12
        return (try NIOSSLContext(configuration: tls), try ControlDial.pin(of: leaf))
    }
}
