import AgentsKitCore
import Foundation
#if canImport(dnssd)
import dnssd

/// Agents Host's single copy on the local network (058, T057): `_agents-control._tcp`
/// under this Mac's name, so the App Store window finds it (frame K2), with the pin in the
/// TXT record so the one found is the one dialled. On the main queue, for as long as the
/// process lives.
final class Advertiser {
    private var service: DNSServiceRef?

    init?(name: String, port: Int, pin: String?) {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        func add(_ key: String, _ value: String) {
            let bytes = Array(value.utf8)
            TXTRecordSetValue(&txt, key, UInt8(bytes.count), bytes)
        }
        add("v", "2")
        if let pin { add("pin", pin) }
        var ref: DNSServiceRef?
        let status = DNSServiceRegister(&ref, 0, 0, name, ControlBonjour.serviceType, nil, nil,
                                        UInt16(port).bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                                        nil, nil)
        guard status == kDNSServiceErr_NoError, let ref else { return nil }
        DNSServiceSetDispatchQueue(ref, .main)
        service = ref
    }

    deinit {
        if let service { DNSServiceRefDeallocate(service) }
    }
}
#endif
