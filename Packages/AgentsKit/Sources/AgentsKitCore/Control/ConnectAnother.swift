import Foundation

/// Settings ▸ Control plane ▸ **Connect to Another…** and **Use This Mac Only** (#4228,
/// spec 4224, "Connecting a control plane"): this Mac's agents report to Hosted at
/// agentloops.dev or to a control plane the person runs, and go back to the one on this Mac.
public enum ConnectAnother {
    /// Where the Mac app signs in to Hosted: the service sends it a client code on
    /// `agents://hosted` (`Go/internal/hosted/app.go`).
    public static let hostedURL = URL(string: "https://agentloops.dev/app/connect")!
    public static let callbackScheme = "agents"

    /// What Hosted said, in the fragment of `agents://hosted#code=…` or `#message=…`.
    public enum Answer: Equatable, Sendable {
        case code(ControlCode)
        case failed(String)
    }

    public static func answer(_ url: URL) -> Answer {
        var parts = URLComponents()
        parts.percentEncodedQuery = url.fragment
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if let text = value("code") {
            guard let code = ControlCode(text: text), code.purpose == .client else { return .failed(Words.hostedNoCode) }
            return .code(code)
        }
        if let message = value("message") { return .failed(message) }
        return .failed(Words.hostedNoCode)
    }

    /// A pasted code, or why it will not do: the window pairs with a client code, then makes
    /// this Mac's machine code itself.
    public static func check(_ typed: String) -> Result<ControlCode, Refusal> {
        guard let code = ControlCode(text: typed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(Refusal(words: Words.notACode))
        }
        guard code.purpose == .client else { return .failure(Refusal(words: Words.machineCode)) }
        return .success(code)
    }

    /// The control plane a code is for, as the sheet names it: its address's host name, such
    /// as `k3v9x0qa7b.cp.agentloops.dev`, else (an IP address, `localhost`) the name it gives
    /// itself.
    public static func place(_ code: ControlCode) -> String {
        guard let host = code.url.flatMap({ URL(string: $0)?.host }), host != "localhost",
              host.contains(where: \.isLetter), !host.contains(":") else { return code.name }
        return host
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let words: String
    }

    public enum Words {
        public static let connect = "Connect to Another…"
        public static let useThisMacOnly = "Use This Mac Only"
        public static let title = "Connect to another control plane"
        public static let lead = "This Mac’s agents report to the control plane on this Mac. They can report to Hosted at agentloops.dev, or to a control plane that you run."
        public static let signIn = "Sign In to agentloops.dev"
        public static let signInNote = "With Apple, Google or GitHub. A new account gets a control plane of its own."
        public static let useCode = "Use a Code…"
        public static let useCodeNote = "From a control plane that you run: Settings ▸ Clients ▸ Pair a Mac there."
        public static let codeNote = "Paste the code, or its link. It works once, for five minutes."
        public static let notACode = "That isn’t a control plane’s code. It starts with agents-control:."
        public static let machineCode = "This is a code for a machine. Use a code from Pair a Mac on that control plane: this window makes this Mac’s machine code itself."
        public static let hostedNoCode = "agentloops.dev gave no code. Try again."

        /// What happens, said before it does (the spec's words).
        public static func before(_ name: String) -> String {
            "This Mac’s agents will report to \(name). Your sessions stay on this Mac. Your iPhone, iPad and browsers must pair again. The control plane on this Mac stops."
        }

        public static let backTitle = "Use this Mac only?"

        /// Use This Mac Only, said before it does.
        public static func back(_ name: String) -> String {
            "This Mac’s agents will stop reporting to \(name), and the control plane on this Mac starts again, as it was. Your sessions stay on this Mac."
        }

        public static let pairing = "Connecting this window…"
        public static let joining = "Joining this Mac…"
        public static let startingHere = "Starting the control plane on this Mac…"
        public static let noMachineCode = "The control plane made no code for this Mac."
    }
}
