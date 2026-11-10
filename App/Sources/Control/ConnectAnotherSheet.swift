import AgentsKitCore
import AuthenticationServices
import SwiftUI

/// Settings ▸ Control plane ▸ **Connect to Another…** (#4228, spec 4224, "Connecting a
/// control plane"): sign in to agentloops.dev, or use a code from a control plane the person
/// runs. The sheet says what will happen before it does it. Then the window pairs with the
/// new control plane, makes this Mac's machine code with that pairing, and the host joins
/// with it (what Join one elsewhere did), which stops the control plane on this Mac.
///
/// The window pairs first because only a client may make a machine code: the host's own
/// membership cannot pair a window (the issue's open question). So the person signs in or
/// pastes once, and both join.
struct ConnectAnotherSheet: View {
    typealias Words = ConnectAnother.Words

    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(AppModel.self) private var model
    let host: HostModel

    enum Step: Equatable {
        case choose
        case code
        case confirm(ControlCode)
        case working(String)
    }

    @State private var step: Step = .choose
    @State private var typed = ""
    @State private var problem: String?
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Words.title).appText(.reading).fontWeight(.semibold)
            switch step {
            case .choose: choose
            case .code: codeStep
            case .confirm(let code): confirm(code)
            case .working(let words):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(words).appText(.reading).foregroundStyle(.secondary)
                }
            }
            if let problem {
                Text(problem).appText(.supporting).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                switch step {
                case .code:
                    Button("Next") { next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .confirm(let code):
                    Button("Connect") { connect(code) }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                case .choose, .working:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool { if case .working = step { true } else { false } }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Words.lead).appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(Words.signIn) { Task { await signIn() } }
                        .buttonStyle(.paperProminent)
                        .disabled(signingIn)
                    if signingIn { ProgressView().controlSize(.small) }
                }
                Text(Words.signInNote).appText(.fine).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button(Words.useCode) {
                    problem = nil
                    step = .code
                }
                .buttonStyle(.paper)
                Text(Words.useCodeNote).appText(.fine).foregroundStyle(.secondary)
            }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("agents-control:…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .appText(.code)
                .onSubmit(next)
            Text(Words.codeNote).appText(.supporting).foregroundStyle(.secondary)
        }
    }

    private func confirm(_ code: ControlCode) -> some View {
        Text(Words.before(ConnectAnother.place(code)))
            .appText(.reading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func next() {
        switch ConnectAnother.check(typed) {
        case .success(let code):
            problem = nil
            step = .confirm(code)
        case .failure(let refusal):
            problem = refusal.words
        }
    }

    /// agentloops.dev in the browser's own session: a person signed in there is not asked again.
    private func signIn() async {
        problem = nil
        signingIn = true
        defer { signingIn = false }
        do {
            let back = try await webAuthenticationSession.authenticate(
                using: ConnectAnother.hostedURL, callback: .customScheme(ConnectAnother.callbackScheme),
                additionalHeaderFields: [:])
            switch ConnectAnother.answer(back) {
            case .code(let code): step = .confirm(code)
            case .failed(let why): problem = why
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    private func connect(_ code: ControlCode) {
        problem = nil
        Task {
            do {
                try await ControlPlaneMove.connect(with: code, host: host, model: model) { step = .working($0) }
                dismiss()
            } catch {
                problem = (error as? ControlPlaneMove.Failure)?.description ?? (error as? MachinePin.Refused)?.words
                    ?? PairingAttempt.sentence(for: error, device: "this Mac")
                step = .choose
            }
        }
    }
}

/// Where Settings ▸ Control plane says where it runs (#4228): **Connect to Another…** while
/// the control plane is on this Mac, **Use This Mac Only** while this Mac's host reports to
/// another (by the host's role: a scratch one can be on this Mac too). Neither while the organisation pins a control plane (FR-027), nor after a
/// move to another machine, which Move… brings back.
struct ControlPlaneMoveButton: View {
    typealias Words = ConnectAnother.Words

    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var connecting = false
    @State private var askingBack = false
    @State private var goingBack = false

    var body: some View {
        if let host = HostScenes.model, let firstOpen = HostScenes.firstOpen, host.pin?.namesAControlPlane != true,
           host.settings.movedTo == nil {
            if host.settings.role == .runHere, control.isOnThisMac {
                Button(Words.connect) { connecting = true }
                    .buttonStyle(.paper)
                    .sheet(isPresented: $connecting) { ConnectAnotherSheet(host: host).paperSheet() }
            } else if host.settings.role == .joinElsewhere {
                HStack(spacing: 8) {
                    if goingBack { ProgressView().controlSize(.small) }
                    Button(Words.useThisMacOnly) { askingBack = true }
                        .buttonStyle(.paper)
                        .disabled(goingBack)
                }
                .confirmationDialog(Words.backTitle, isPresented: $askingBack) {
                    Button(Words.useThisMacOnly) { goBack(host, firstOpen) }
                } message: {
                    Text(Words.back(control.status?.name ?? control.whereItIs))
                }
            }
        }
    }

    private func goBack(_ host: HostModel, _ firstOpen: FirstOpen) {
        goingBack = true
        Task {
            do {
                try await ControlPlaneMove.useThisMacOnly(host: host, firstOpen: firstOpen, model: model)
            } catch {
                control.problem = (error as? ControlPlaneMove.Failure)?.description ?? "\(error)"
            }
            goingBack = false
        }
    }
}

/// The steps of Connect to Another… and Use This Mac Only (#4228), apart from the sheet.
@MainActor
enum ControlPlaneMove {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The window pairs with `code`, makes this Mac's machine code there, and the host joins
    /// with it. Until the host has joined, a failure leaves the window paired as it was.
    static func connect(with code: ControlCode, host: HostModel, model: AppModel,
                        step: (String) -> Void) async throws {
        let kept = ControlConfig.keptPairing()
        if host.settings.role == .runHere { ControlConfig.keepHerePairing(kept) }
        step(ConnectAnother.Words.pairing)
        let membership = try await ControlConfig.pair(with: code)
        do {
            step(ConnectAnother.Words.joining)
            let machineCode = try await machineCode(at: membership)
            host.problem = nil
            await host.joinElsewhere(code: machineCode)
            if let problem = host.problem { throw Failure(description: problem) }
        } catch {
            ControlConfig.putBack(kept)
            throw error
        }
        await model.moveControlPlane(to: .remote(membership))
    }

    /// A machine code from the control plane the window has just paired with, with an invite
    /// on its machine lock as Add a Machine makes one (#3491).
    private static func machineCode(at membership: ControlMembership) async throws -> String {
        guard let control = ControlSettingsModel(endpoint: .remote(membership)) else {
            throw Failure(description: ConnectAnother.Words.noMachineCode)
        }
        defer { control.stop() }
        await control.refresh()
        guard let shown = await control.startCode(forHost: true) else {
            throw Failure(description: control.problem ?? ConnectAnother.Words.noMachineCode)
        }
        return shown.text
    }

    /// Use This Mac Only: the host leaves the control plane elsewhere, the first open's steps
    /// start the one on this Mac again, and the window goes back with the pairing it had
    /// there, or pairs afresh by itself.
    static func useThisMacOnly(host: HostModel, firstOpen: FirstOpen, model: AppModel) async throws {
        try await host.leaveElsewhere()
        await firstOpen.run { code in
            let membership: ControlMembership
            if let kept = ControlConfig.takeHerePairing() { membership = kept } else { membership = try await ControlConfig.pair(with: code) }
            await model.moveControlPlane(to: .remote(membership))
        }
        switch firstOpen.step {
        case .failed(let line, _): throw Failure(description: line)
        // The organisation pins a control plane elsewhere (FR-027).
        case .elsewhere: throw Failure(description: host.pin?.refusal ?? host.problem ?? ConnectAnother.Words.noMachineCode)
        case .working: return
        }
    }
}
