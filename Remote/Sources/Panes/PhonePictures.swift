import AgentsKitCore
import UIKit
import WebKit

/// The pictures a page shows, read from the Mac and kept while the app runs (034).
///
/// Each is held with the stamp it was read at, so asking again whether it changed costs
/// one small request and no bytes: the Mac answers `unchanged` until the file moves.
@MainActor
final class PhonePictures {
    private struct Held {
        var stamp: FileStamp
        var image: UIImage?
        /// The bytes of a picture that could not be drawn, kept so the next ask draws it
        /// again rather than being told "unchanged" and handed nothing for ever.
        var undrawn: Data?
        var attempts = 0
    }

    /// How many times one version of a picture is drawn before the page is left with its
    /// alternative text.
    private static let attemptsAllowed = 3

    private let files: RemoteFiles
    private var held: [URL: Held] = [:]
    /// One read and draw per picture at a time. The page asks for a picture's stamp and
    /// for the picture itself at the same moment, and two web views drawing the same
    /// markup side by side is one too many.
    private var working: [URL: Task<Held?, Never>] = [:]

    init(files: RemoteFiles) {
        self.files = files
    }

    /// What the picture's file is now, reading it again only if it changed.
    func stamp(agentID: UUID, url: URL) async -> FileStamp? {
        await refresh(agentID: agentID, url: url)?.stamp
    }

    func image(agentID: UUID, url: URL) async -> UIImage? {
        if let image = held[url]?.image { return image }
        return await refresh(agentID: agentID, url: url)?.image
    }

    private func refresh(agentID: UUID, url: URL) async -> Held? {
        if let running = working[url] { return await running.value }
        let task = Task { await self.read(agentID: agentID, url: url) }
        working[url] = task
        let result = await task.value
        working[url] = nil
        return result
    }

    private func read(agentID: UUID, url: URL) async -> Held? {
        let known = held[url]
        // A picture that could not be drawn is drawn again from the bytes already here,
        // a few times, before its file is asked about again.
        if var retry = known, let bytes = retry.undrawn, retry.attempts < Self.attemptsAllowed {
            retry.attempts += 1
            if let image = await Self.decode(bytes, isSVG: Self.isSVG(url)) {
                retry.image = image
                retry.undrawn = nil
            }
            held[url] = retry
            return retry
        }
        guard let reading = try? await files.read(agentID: agentID, path: url.path, known: known?.stamp) else {
            return known
        }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let image = await Self.decode(bytes, isSVG: Self.isSVG(url))
            let fresh = Held(stamp: stamp, image: image, undrawn: image == nil ? bytes : nil, attempts: 1)
            held[url] = fresh
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held[url] = fresh
            return fresh
        }
    }

    private static func isSVG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    private static func decode(_ bytes: Data, isSVG: Bool) async -> UIImage? {
        if isSVG { return await SVGRaster.image(from: bytes) }
        return UIImage(data: bytes)
    }
}

/// An SVG, drawn by WebKit and kept as a picture.
///
/// UIKit has no SVG decoder and neither has ImageIO (research §3), and an agent's
/// diagrams are SVG more often than not. So the markup is drawn once in a web view
/// nobody sees, photographed, and the photograph is what the page shows. The page itself
/// stays native.
///
/// The markup is the agent's, so it is drawn with its scripts off and every network load
/// refused: a picture on the page makes no request on the document's behalf (022 FR-011).
@MainActor
enum SVGRaster {
    /// The widest a picture is drawn. The page is narrower than this on every device,
    /// and the snapshot is taken at the screen's scale.
    static let widest: CGFloat = 1_200

    private static var blockNetwork: WKContentRuleList?

    static func image(from bytes: Data) async -> UIImage? {
        let markup = String(decoding: bytes, as: UTF8.self)
        guard markup.contains("<svg") else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rules = await networkRules() { configuration.userContentController.add(rules) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: widest, height: 10), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear

        // A snapshot of a web view that is in no window comes out blank, so it is put in
        // one: a window of its own, behind the app's, for as long as it takes. Not the
        // app's own window: on an iPhone the page is pushed onto the screen, and a web
        // view drawn into a window in the middle of that animation photographed as
        // nothing — the iPad, where the page is a column and nothing moves, drew fine.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: widest, height: 2_000)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        window.isHidden = false
        window.addSubview(view)
        defer {
            view.removeFromSuperview()
            window.isHidden = true
        }

        let html = """
            <!doctype html><html><head>
            <meta name="viewport" content="width=\(Int(widest))">
            <style>html,body{margin:0;padding:0;background:transparent}
            svg{display:block;max-width:100%;height:auto}</style>
            </head><body>\(markup)</body></html>
            """
        let loader = Loader()
        view.navigationDelegate = loader
        view.loadHTMLString(html, baseURL: nil)
        guard await loader.finished() else { return nil }

        // The drawing's own size, as the page laid it out.
        let size = (try? await view.evaluateJavaScript(
            "(() => { const r = document.querySelector('svg').getBoundingClientRect(); return [r.width, r.height]; })()"
        )) as? [Double]
        guard let size, size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size[0], height: size[1])
        view.frame.size = CGSize(width: widest, height: size[1])

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = rect
        snapshot.afterScreenUpdates = true
        // A snapshot taken before WebKit has painted is a picture of nothing, and a
        // transparent picture on the page looks exactly like a missing one. So it is
        // looked at, and taken again after a beat if there is nothing in it.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250 * attempt)) }
            if let image = try? await view.takeSnapshot(configuration: snapshot), !isBlank(image) {
                return image
            }
        }
        return nil
    }

    /// Whether a picture has nothing in it: every pixel transparent. Looked at small,
    /// because a diagram is lines and fills and any of them shows at a sixteenth.
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let width = max(1, cg.width / 4), height = max(1, cg.height / 4)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    /// Every load from the network, refused. Compiled once.
    private static func networkRules() async -> WKContentRuleList? {
        if let blockNetwork { return blockNetwork }
        let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
        let compiled = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "agents.page.no-network", encodedContentRuleList: rules)
        blockNetwork = compiled
        return compiled
    }

    /// Waits for the one load a raster makes.
    @MainActor
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func finished() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        private func end(_ ok: Bool) {
            guard result == nil else { return }
            result = ok
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { end(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { end(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) { end(false) }
    }
}
