#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Security

/// The control plane's listener, reduced to the lock `LinkTLS` puts on it (058, R8).
///
/// TLS 1.2 only, one suite (`0xCCAC`), one pre-shared key, no resumption. Prints `ready`
/// on stdout once it is listening, then `agreed` when a client finishes the handshake
/// on that suite, and answers `ok` to a line.
fputs("booting\n", stderr)
fflush(stderr)
let args = CommandLine.arguments
guard args.count == 4, let port = UInt16(args[1]) else {
    fputs("usage: psk-listen <port> <identity> <keyhex>\n", stderr)
    exit(2)
}
let identity = args[2]
let key = hex(args[3])
guard key.count == 32 else {
    fputs("the key must be 32 bytes\n", stderr)
    exit(2)
}

let tls = NWProtocolTLS.Options()
let sec = tls.securityProtocolOptions
sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0xCCAC)!)
sec_protocol_options_set_tls_resumption_enabled(sec, false)
sec_protocol_options_set_tls_tickets_enabled(sec, false)
let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
sec_protocol_options_add_pre_shared_key(sec, keyData, idData)
sec_protocol_options_set_pre_shared_key_selection_block(sec, { _, offered, complete in
    let offeredID = offered.map { String(decoding: Data($0 as DispatchData), as: UTF8.self) }
    complete(offeredID == identity ? offered : nil)
}, DispatchQueue(label: "psk-listen"))

let parameters = NWParameters(tls: tls)
parameters.allowLocalEndpointReuse = true
let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
let done = DispatchSemaphore(value: 0)
let queue = DispatchQueue(label: "psk-listen")
listener.newConnectionHandler = { connection in
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            let metadata = (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
                .securityProtocolMetadata
            let suite = metadata.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0).rawValue } ?? 0
            print("agreed \(String(format: "%04x", suite))", terminator: "\n")
            fflush(stdout)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, _, _ in
                connection.send(content: Data("ok\n".utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    done.signal()
                })
            }
        }
    }
    connection.start(queue: queue)
}
listener.stateUpdateHandler = { state in
    fputs("listener \(state)\n", stderr)
    fflush(stderr)
    if case .ready = state {
        print("ready")
        fflush(stdout)
    }
    if case .failed(let error) = state {
        fputs("listener failed: \(error)\n", stderr)
        fflush(stderr)
        done.signal()
    }
}
listener.start(queue: queue)
// The main thread has to stay in the run loop. Waiting on it here keeps the
// listener from ever becoming ready.
dispatchMain()

func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        guard next > index, let byte = UInt8(text[index..<next], radix: 16) else { return [] }
        bytes.append(byte)
        index = next
    }
    return bytes
}
#else
fputs("psk-listen is the Mac listener\n", stderr)
exit(1)
#endif
