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
    }

    private let files: RemoteFiles
    private var held: [URL: Held] = [:]

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
        let known = held[url]
        guard let reading = try? await files.read(agentID: agentID, path: url.path, known: known?.stamp) else {
            return known
        }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let image = await Self.decode(bytes, isSVG: url.pathExtension.lowercased() == "svg")
            let fresh = Held(stamp: stamp, image: image)
            held[url] = fresh
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held[url] = fresh
            return fresh
        }
    }

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
        // one, off the edge of the screen, for as long as it takes.
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        view.frame.origin = CGPoint(x: -widest * 2, y: 0)
        window.addSubview(view)
        defer { view.removeFromSuperview() }

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
        return try? await view.takeSnapshot(configuration: snapshot)
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
