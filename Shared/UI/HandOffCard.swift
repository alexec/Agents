import AgentsKitCore
import SwiftUI

/// An agent's `hand_to_person` (#3529), drawn by the window's `ElicitationView` and the
/// Remote's `ElicitationSheet` under their own "who asks" line: the step, why, Open the page
/// where this client can show the machine's browser, Done, and Can't do it with a line
/// for what stopped them.
struct HandOffCard: View {
    let handOff: ElicitationRequest.HandOff
    /// Opens the Agent Browser at the agent's tab; nil where this client cannot.
    let open: (@MainActor () -> Void)?
    /// Said in place of Open the page, where `open` is nil; nil says nothing, as where the
    /// page is open already (a take-over window, #4141).
    let elsewhere: String?
    /// Who is told: "your Mac", or the agent's server.
    let host: String
    /// An answer is on the way: the card is held until the daemon takes it down.
    let sending: Bool
    /// Done (true), or Can't do it (false) with what stopped them.
    let send: @MainActor (_ done: Bool, _ note: String) -> Void
    @State private var cannot = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    /// Said in place of Open the page for a step in one of the agents' own Chrome windows
    /// (#5095): "Do it in the agents' Chrome (DevTools port 9233), … on your Mac."
    static func inWindow(_ window: String, on host: String) -> String {
        "Do it in \(window) on \(host)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The step or the name is the Ask's title (AskCard, #5031).
            if let reason = handOff.reason, !reason.isEmpty {
                Text(reason).appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if open == nil, let elsewhere {
                Text(elsewhere).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cannot {
                TextField("What stopped you (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .onSubmit { send(false, note) }
                    .disabled(sending)
            }
            // The Ask's foot (#5031): Can't do it as a link on the left, Done, and Open the
            // page the primary on the right.
            Divider().overlay(Paper.rule)
            HStack(spacing: 8) {
                if sending { Telling(host: host) }
                if !cannot {
                    AskDecline("Can't do it") {
                        cannot = true
                        noteFocused = true
                    }
                    .appText(.fine)
                    .disabled(sending)
                }
                Spacer(minLength: 0)
                if cannot {
                    Button("Back") { cannot = false }
                        .buttonStyle(.paper)
                        .disabled(sending)
                    Button("Send") { send(false, note) }
                        .buttonStyle(.paperProminent)
                        .disabled(sending)
                } else {
                    if let open {
                        Button("Done") { send(true, "") }
                            .buttonStyle(.paper)
                            .disabled(sending)
                        Button("Open the page", action: open)
                            .buttonStyle(.paperProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(sending)
                    } else {
                        Button("Done") { send(true, "") }
                            .buttonStyle(.paperProminent)
                            .disabled(sending)
                    }
                }
            }
        }
    }
}
