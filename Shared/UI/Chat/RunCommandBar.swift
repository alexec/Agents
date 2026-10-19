import AgentsKitCore
import SwiftUI

/// Run a shell command from a reply (#1533): under a `sh`, `bash`, `zsh` or `console` block
/// in an agent's reply. Run types the command into the session's shell, in its folder, and
/// shows the shell; it never runs without the press. Once run, Tell the Agent sends the
/// command and the end of what it printed to the session, for when it did not work.
struct RunCommandBar: View {
    @Environment(\.chatActions) private var actions
    let command: String
    @State private var ran = false

    var body: some View {
        if let run = actions.runCommand {
            HStack(spacing: 14) {
                Button {
                    run(command)
                    ran = true
                } label: {
                    Label("Run", systemImage: "play")
                }
                .help("Type this into the session's shell and run it")
                if ran, let tell = actions.tellAgent {
                    Button {
                        tell(command)
                    } label: {
                        Label("Tell the Agent", systemImage: "arrow.uturn.left")
                    }
                    .help("Send the command and the end of what it printed to the agent")
                }
            }
            .appText(.supporting)
            .buttonStyle(.borderless)
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
        }
    }
}
