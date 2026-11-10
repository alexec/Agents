import SwiftUI

/// Why the person declines a form (#4039), drawn by the window's `ElicitationView` and the
/// Remote's `ElicitationSheet` when they choose No, because… in place of No thanks: one line,
/// Back and Send. Return sends and Escape goes back. The agent reads what is typed; an empty
/// line declines with no reason, as No thanks does.
struct DeclineReasonField: View {
    /// Who is told: "your Mac", or the agent's server.
    let host: String
    /// An answer is on the way: the field is held until the daemon takes the card down.
    let sending: Bool
    let back: @MainActor () -> Void
    let send: @MainActor (_ reason: String) -> Void
    @State private var reason = ""
    @FocusState private var focused: Bool

    /// The title of the control that opens this field, on every client.
    static let opener = "No, because…"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Why not? The agent reads this", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { send(reason) }
                .onKeyPress(.escape) {
                    back()
                    return .handled
                }
                .disabled(sending)
            HStack(spacing: 8) {
                if sending { Telling(host: host) }
                Spacer(minLength: 0)
                Button("Back", action: back)
                    .buttonStyle(.paper)
                    .disabled(sending)
                Button("Send") { send(reason) }
                    .buttonStyle(.paperProminent)
                    .disabled(sending)
            }
        }
        .onAppear { focused = true }
    }
}
