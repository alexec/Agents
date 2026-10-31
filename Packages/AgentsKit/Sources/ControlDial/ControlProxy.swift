import Foundation
import NIOCore
#if canImport(CFNetwork)
import CFNetwork
#endif

/// The proxy a dial to the control plane goes through, on a corporate network (#2177):
/// `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` when any is set, as on Linux; otherwise, on a
/// Mac, the proxy System Settings ▸ Network ▸ Proxies gives for the address, with its
/// exceptions. A proxy auto-configuration (PAC) file is not run here; the window's own
/// link, through URLSession, follows it. Loopback is never sent to a proxy.
///
/// The tunnel is HTTP CONNECT, so TLS, the pin and the key exchange are end to end, as
/// without a proxy.
public struct ControlProxy: Sendable, Equatable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The proxy for `url`, or nil to go straight there.
    public static func forURL(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ControlProxy? {
        guard let host = url.host?.lowercased(), !isLoopback(host) else { return nil }
        let secure = ["https", "wss"].contains(url.scheme?.lowercased() ?? "")
        let names = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"]
        if names.contains(where: { !(environment[$0] ?? "").isEmpty }) {
            return fromEnvironment(host: host, secure: secure, environment: environment)
        }
        #if canImport(CFNetwork)
        return fromSystem(host: host, port: url.port, secure: secure)
        #else
        return nil
        #endif
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// `HTTPS_PROXY` for https and wss, `HTTP_PROXY` for http and ws, unless `NO_PROXY` names
    /// the host: `*`, a name, or a `.domain` (a bare `domain` covers its subdomains too).
    static func fromEnvironment(host: String, secure: Bool, environment: [String: String]) -> ControlProxy? {
        func value(_ name: String) -> String? {
            [environment[name], environment[name.lowercased()]].compactMap { $0 }.first { !$0.isEmpty }
        }
        for entry in (value("NO_PROXY") ?? "").split(separator: ",") {
            var e = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if e == "*" { return nil }
            if let colon = e.lastIndex(of: ":"), !e.contains("]"), e.filter({ $0 == ":" }).count == 1 { e = String(e[..<colon]) }
            if e.hasPrefix("*") { e.removeFirst() }
            if e.hasPrefix(".") { e.removeFirst() }
            if !e.isEmpty, host == e || host.hasSuffix("." + e) { return nil }
        }
        guard let text = secure ? value("HTTPS_PROXY") : value("HTTP_PROXY") else { return nil }
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let proxy = URL(string: withScheme), let proxyHost = proxy.host else { return nil }
        return ControlProxy(host: proxyHost, port: proxy.port ?? (proxy.scheme == "https" ? 443 : 80))
    }

    #if canImport(CFNetwork)
    /// What CFNetwork says for the address: its exceptions are the system's own.
    static func fromSystem(host: String, port: Int?, secure: Bool) -> ControlProxy? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return nil }
        var parts = URLComponents()
        parts.scheme = secure ? "https" : "http"
        parts.host = host
        parts.port = port
        guard let url = parts.url,
              let list = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[CFString: Any]]
        else { return nil }
        for entry in list {
            let type = entry[kCFProxyTypeKey] as? String
            if type == (kCFProxyTypeNone as String) { return nil }
            guard type == (kCFProxyTypeHTTPS as String) || type == (kCFProxyTypeHTTP as String),
                  let proxyHost = entry[kCFProxyHostNameKey] as? String,
                  let proxyPort = entry[kCFProxyPortNumberKey] as? Int else { continue }
            return ControlProxy(host: proxyHost, port: proxyPort)
        }
        return nil
    }
    #endif
}

/// Opens an HTTP CONNECT tunnel through the proxy, then hands the channel to `then`, which
/// adds TLS and the WebSocket upgrade as if connected straight to the control plane.
final class ProxyTunnel: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let target: String
    let then: (any Channel) throws -> Void
    let failed: @Sendable (any Error) -> Void
    private var answer: ByteBuffer?

    init(target: String, then: @escaping (any Channel) throws -> Void, failed: @escaping @Sendable (any Error) -> Void) {
        self.target = target
        self.then = then
        self.failed = failed
    }

    func channelActive(context: ChannelHandlerContext) {
        var request = context.channel.allocator.buffer(capacity: 128)
        request.writeString("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if answer == nil { answer = bytes } else { answer!.writeBuffer(&bytes) }
        guard var buffered = answer,
              let text = buffered.getString(at: buffered.readerIndex, length: buffered.readableBytes),
              let end = text.range(of: "\r\n\r\n") else {
            if (answer?.readableBytes ?? 0) > 16 << 10 { fail(context, "the proxy's answer is too long") }
            return
        }
        let head = text[..<end.lowerBound]
        let status = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let code = status.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard code == "200" else {
            return fail(context, "the proxy refused the tunnel to \(target): \(status)")
        }
        buffered.moveReaderIndex(forwardBy: text.utf8.distance(from: text.startIndex, to: end.upperBound))
        answer = nil
        let channel = context.channel
        channel.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        do {
            try then(channel)
        } catch {
            failed(error)
            return channel.close(promise: nil)
        }
        // Anything the control plane already said, behind the proxy's answer.
        if buffered.readableBytes > 0 { channel.pipeline.syncOperations.fireChannelRead(NIOAny(buffered)) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failed(error)
        context.close(promise: nil)
    }

    private func fail(_ context: ChannelHandlerContext, _ why: String) {
        failed(ControlDial.Failure(why))
        context.close(promise: nil)
    }
}
