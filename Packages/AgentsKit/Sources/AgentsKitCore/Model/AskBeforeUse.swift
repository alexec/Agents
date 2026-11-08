import Foundation

/// The words of Ask before use (#4014, #4016), on the Secrets page, For One Session and the
/// `ask_secret` card. On, only the machine's host uses the value: to fill a page, to set a CI
/// secret or to call an HTTP MCP server. Off, every session on the machine can read it. The web
/// page's are the same, in `Web/src/model/askBeforeUse.ts`.
public enum AskBeforeUseWords {
    /// The toggle.
    public static let toggle = "Ask before use"
    /// On a secret's row when the flag is on.
    public static let asks = "Asks before use"
    /// Under the toggle when it is on.
    public static let on = "Only fill_secret, set_ci_secret and HTTP MCP servers can use it. It is not in $NAME or in a file."
    /// Under the toggle when it is off.
    public static let off = "Every session on the machine can read it, as $NAME and from a file."

    public static func hint(_ isOn: Bool) -> String { isOn ? on : off }
}
