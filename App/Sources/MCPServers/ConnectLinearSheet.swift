import AgentsKitCore
import SwiftUI

/// Connect Linear (#1343, frame H): the Connect GitHub sheet's shape, for Linear's
/// authorization code with PKCE. Continue on linear.app asks the host for the address, opens
/// it in an authentication session, and gives the code that comes back to the host
/// (CodeFlowSignIn). The sheet closes by itself once the host says connected.
struct ConnectLinearSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var session

    var host: MachineRef
    var onConnected: () -> Void = {}

    private enum Step: Equatable {
        case asking
        case starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case finishing
        case failed(String)
    }

    @State private var step: Step = .asking

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.linear), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Linear").appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.linear)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.linear).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                Text(ConnectorSetupWords.sheetChoose(.linear)).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(ConnectorSetupWords.sheetFoot).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                switch step {
                case .asking:
                    Button(ConnectorSetupWords.continueButton(.linear)) { Task { await start() } }
                        .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Try Again") { Task { await start() } }.buttonStyle(.paperProminent)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .paperSheet()
        .onDisappear {
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .asking:
            EmptyView()
        case .starting, .finishing, .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusWords).appText(.fine).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusWords: String {
        switch step {
        case .waiting(let flow): ConnectorSetupWords.sheetStatus(flow)
        case .finishing: ConnectorSetupWords.Linear.finishing
        default: "Asking the machine for Linear's address\u{2026}"
        }
    }

    private func start() async {
        step = .starting
        let flow: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.linear, on: host) {
        case .success(let started): flow = started
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(flow)
        let outcome: CodeFlowSignIn.Outcome
        if let folder = ControlConfig.walkFolder {
            outcome = await handOff(flow, to: folder)
        } else {
            outcome = await CodeFlowSignIn.finish(flow, in: session) { request in
                step = .finishing
                return await model.completeSignIn(request, on: host).mapError { CodeFlowSignIn.Problem($0.words) }
            }
        }
        switch outcome {
        case .connected:
            onConnected()
            dismiss()
        case .cancelled:
            await model.cancelSignIn(flow.flowID, on: host)
            step = .asking
        case .failed(let why):
            step = .failed(why)
        }
    }

    /// A walk's window (#1794) opens no authentication session: that would be Safari's sheet
    /// on the person's screen. It writes the flow and its address to `sign-in.json` in the
    /// walk's folder, as Open in Browser writes `opened-url` (#109). The walk approves in its
    /// own browser, gives the code to the host (`connections/sign-in/complete`), and this
    /// waits for the host to say how the sign-in ended.
    private func handOff(_ flow: DaemonAPI.ConnectionSignIn, to folder: URL) async -> CodeFlowSignIn.Outcome {
        let note = ["flowID": flow.flowID.uuidString, "address": flow.verificationURL]
        guard let data = try? JSONSerialization.data(withJSONObject: note),
              (try? data.write(to: folder.appendingPathComponent("sign-in.json"), options: .atomic)) != nil  // store-ok: the window's own container
        else { return .failed("The walk's sign-in could not be handed on.") }
        while !Task.isCancelled {
            switch await model.waitForSignIn(flow.flowID, on: host) {
            case .failure(let problem):
                return .failed(problem.words)
            case .success(let ended) where ended.status == .waiting:
                continue
            case .success(let ended) where ended.status == .connected:
                return .connected(ended)
            case .success(let ended) where ended.status == .cancelled:
                return .cancelled
            case .success(let ended):
                return .failed(ConnectorSetupWords.sheetStatus(ended))
            }
        }
        return .cancelled
    }

    private func cancel() async {
        if case .waiting(let flow) = step {
            step = .asking
            await model.cancelSignIn(flow.flowID, on: host)
        }
        dismiss()
    }
}
