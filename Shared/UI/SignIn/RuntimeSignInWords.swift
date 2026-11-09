import Foundation

/// The words of Sign In… on a server's Claude or Codex (#3349, #4035): the web page's
/// `machineSignInWords` (Web/src/model/runtimes.ts) says the same.
enum RuntimeSignInWords {
    static func title(_ runtime: String, machine: String) -> String { "Sign In to \(runtime) on \(machine)" }
    static func asking(_ runtime: String) -> String { "Asking \(runtime) for a link…" }
    static let openLink = "Open this link, and sign in to your account:"
    static let open = "Open Link"
    static let copyLink = "Copy Link"
    static let pasteCode = "Then paste the code the page gives:"
    static let typeCode = "Then type this code on the page:"
    static let codexNote = "If OpenAI does not take the code, turn on device code sign-in in ChatGPT’s security settings."
    static let codeLabel = "Code"
    static let useKey = "Use an API Key Instead"
    static let useAccount = "Sign In to an Account Instead"
    static let keyLabel = "API key"
    static func keyNote(_ runtimeID: String) -> String {
        runtimeID == "claude"
            ? "An Anthropic API key, or a token that claude setup-token made on another computer. It is kept on the machine."
            : "An OpenAI API key. Codex keeps it on the machine."
    }
    static let signIn = "Sign In"
    static let done = "Done"
    static let signingIn = "Signing in…"
    /// On This Mac, whose daemon signs its runtimes in only from the Mac.
    static let onTheMac = "Sign it in on the Mac, in Status."
}
