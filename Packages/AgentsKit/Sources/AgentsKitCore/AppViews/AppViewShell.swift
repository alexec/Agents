import Foundation

/// The page a view is drawn inside on the Mac and the phone (#187), as text, so the
/// renderers in both apps load the same thing and the tests can read it.
///
/// A view speaks to `window.parent`, so it has to be in a frame. The web view loads this
/// shell at `agents-view://view/`, under the view's own policy, and the shell holds one
/// `<iframe sandbox="allow-scripts">` with the view's HTML as its `srcdoc`:
///
/// - **No origin.** Without `allow-same-origin` the view's frame is an opaque origin: no
///   cookies, no storage, nothing of the shell's or the app's to read. Nothing else is
///   allowed: no popups, no forms, no moving the top page.
/// - **The policy twice.** In the shell's response and `<meta>`, which a `srcdoc` frame
///   inherits, and again at the top of the view's own `<head>`. Policies only ever add up,
///   so neither copy can loosen the other.
/// - **The bridge out of reach.** The script that carries messages runs in a content world
///   of the app's own (`AppViewShell.world`), main frame only. It sees the frame's
///   `postMessage`s, takes only those whose source is the view's frame, and hands them to
///   the one message handler, which exists in that world and no other. The view can post
///   to its parent, which is all MCP Apps asks of it, and cannot see or call anything else.
public enum AppViewShell {
    /// The scheme the shell is loaded at. Answered by nothing: a view that asks it for a
    /// file is refused.
    public static let scheme = "agents-view"
    /// Where the shell is put.
    public static let address = URL(string: "\(scheme)://view/")!
    /// The content world the bridge runs in, and the one handler's name in it.
    public static let world = "agents-view-host"
    public static let handler = "agentsView"

    /// The shell around one view's HTML, under `policy`.
    public static func page(html: String, policy: AppViewPolicy) -> String {
        let header = escapeAttribute(policy.header)
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(header)">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 0; overflow: hidden; background: light-dark(#f7f8f9, #1c1d20); }
            iframe { display: block; border: 0; width: 100%; height: 100vh; background: transparent; }
            </style></head>
            <body><iframe id="view" title="View" sandbox="allow-scripts" srcdoc="\(escapeAttribute(withPolicy(html, policy)))"></iframe></body></html>
            """
    }

    /// The view's HTML with the policy at the top of its `<head>`, before anything of its
    /// own can run or load.
    public static func withPolicy(_ html: String, _ policy: AppViewPolicy) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(policy.header))\">"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: meta, at: head.upperBound)
            return out
        }
        if let open = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: "<head>\(meta)</head>", at: open.upperBound)
            return out
        }
        return "<head>\(meta)</head>" + html
    }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The bridge, run in `world` at the end of the shell's load. `send(text)` posts one
    /// message to the view; everything the view posts goes to the handler as text.
    public static let bridgeScript = """
        (() => {
          const frame = document.getElementById("view");
          const native = window.webkit.messageHandlers.\(handler);
          window.addEventListener("message", (event) => {
            if (!frame || event.source !== frame.contentWindow) return;
            let text;
            try { text = JSON.stringify(event.data); } catch (e) { return; }
            if (typeof text === "string" && text.length < 4194304) native.postMessage(text);
          });
          window.agentsSendToView = (text) => {
            if (frame && frame.contentWindow) frame.contentWindow.postMessage(JSON.parse(text), "*");
          };
        })();
        """
}
