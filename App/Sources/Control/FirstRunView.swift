import AgentsKit
import AgentsKitCore
import ServiceManagement
import SwiftUI

/// What a window with no control plane shows (058, frames A and B): one question, and
/// nothing else — no sidebar, no toolbar — until it is answered.
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @State private var setup: RunHereSetup?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let setup {
                RunHereProgress(setup: setup)
            } else {
                choice
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperGround()
        .sheet(isPresented: $connecting) {
            ConnectSheet().paperSheet()
        }
    }

    // MARK: A · the question

    private var choice: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Where should your agents run?").appText(.title).fontWeight(.semibold)
            (Text("Agents runs your agents on a ") + Text("control plane").bold()
             + Text(": a small program on a machine you own. This window, your iPhone and your iPad all connect to it, and it reaches every Mac and server your agents work on."))
                .appText(.reading).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                card(title: "Run one on this Mac",
                     body: "Sets up the control plane and this Mac’s agents here. macOS keeps them running, even with this window closed. Your agents stop while this Mac sleeps.",
                     usual: true) {
                    Button("Run One Here") { runHere() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                card(title: "Connect to a control plane",
                     body: "You already run one, on another Mac or a server. You’ll need a pairing code from it.",
                     usual: false) {
                    Button("Connect…") { connecting = true }
                }
            }
            Text("Nothing passes through a service of ours. You can change this later in Settings ▸ Control plane.")
                .appText(.supporting).foregroundStyle(.secondary)
        }
    }

    private func card(title: String, body: String, usual: Bool,
                      @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(body).appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(usual ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: usual ? 2 : 1)
        }
        // One element per card, so the accessibility tree is not a stack of labels over
        // labels; the button inside stays its own element.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func runHere() {
        let setup = RunHereSetup(services: .forThisWindow)
        self.setup = setup
        Task {
            if let root = await setup.run() { await model.adoptControlPlane(root: root) }
        }
    }
}

// MARK: B · setting up

/// The four steps of Run one on this Mac, each as it stands.
@MainActor
@Observable
final class RunHereSetup {
    enum Step: Int, CaseIterable, Identifiable {
        case control, host, background, window
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .control: "Control plane started"
            case .host: "This Mac added as a host"
            case .background: "Allowing Agents in the background"
            case .window: "Pairing this window"
            }
        }
    }

    enum State: Equatable {
        case waiting, working, done
        case failed(String)
    }

    let services: LocalServices
    private(set) var states: [Step: State] = [:]
    /// Said beside the background step while macOS wants the person's say.
    private(set) var approvalNote: String?

    init(services: LocalServices) {
        self.services = services
        for step in Step.allCases { states[step] = .waiting }
    }

    func state(_ step: Step) -> State { states[step] ?? .waiting }

    var failure: String? {
        for step in Step.allCases { if case .failed(let why) = state(step) { return why } }
        return nil
    }

    /// Runs every step, and hands back the control root once the window may use it.
    func run() async -> URL? {
        states[.background] = .working
        switch await services.register() {
        case .enabled:
            break
        case .needsApproval:
            approvalNote = "macOS may ask you in System Settings ▸ Login Items"
            SMAppService.openSystemSettingsLoginItems()
            guard await waitForApproval() else {
                states[.background] = .failed("Agents isn’t allowed in the background yet. Allow it in System Settings ▸ Login Items, then try again.")
                return nil
            }
        case .failed(let why):
            states[.background] = .failed(why)
            return nil
        }

        states[.control] = .working
        let link = ControlConfig.link(root: services.controlRoot)
        let control = DaemonClient(link: link.controlLink)
        guard await within(.seconds(60), { (try? await control.connect(startIfNeeded: false, timeout: .seconds(2))) != nil }) else {
            states[.control] = .failed("The control plane didn’t start. Its log is in \(services.controlRoot.path).")
            return nil
        }
        states[.control] = .done

        states[.host] = .working
        let machine = MachineID.current
        guard await within(.seconds(60), {
            let hosts = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
            return hosts?.contains { $0.machineID == machine && $0.state == "online" } == true
        }) else {
            states[.host] = .failed("This Mac’s agents didn’t join the control plane. Their log is in \(services.hostRoot.path).")
            return nil
        }
        states[.host] = .done
        states[.background] = .done
        approvalNote = nil
        await control.disconnect()
        link.disconnect()

        // The local socket is the pairing: only this app, by its signature, is an
        // operator there (R5). A code comes with pairing another Mac.
        states[.window] = .working
        states[.window] = .done
        return services.controlRoot
    }

    private func waitForApproval() async -> Bool {
        await within(.seconds(300)) { [services] in
            await services.register() == .enabled
        }
    }

    private func within(_ limit: Duration, _ check: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

struct RunHereProgress: View {
    let setup: RunHereSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Setting up on this Mac").appText(.title).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(RunHereSetup.Step.allCases) { step in
                    row(step)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)) }
            if let failure = setup.failure {
                Text(failure).appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            (Text("Two background items appear under Login Items: ") + Text("Agents").bold()
             + Text(" (your agents on this Mac) and ") + Text("Agents Control").bold()
             + Text(". Turning either off stops your agents being reachable."))
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ step: RunHereSetup.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(setup.state(step))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).appText(.reading)
                if step == .background, let note = setup.approvalNote {
                    Text(note).appText(.supporting).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title): \(words(setup.state(step)))")
    }

    @ViewBuilder private func icon(_ state: RunHereSetup.State) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark").foregroundStyle(.green)
        case .working: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark").tinted(.failure)
        }
    }

    private func words(_ state: RunHereSetup.State) -> String {
        switch state {
        case .done: "done"
        case .working: "in progress"
        case .waiting: "waiting"
        case .failed(let why): "failed, \(why)"
        }
    }
}
