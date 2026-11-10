import AgentsKitCore
import AppKit
import AuthenticationServices

/// Connect to Another… asked by a client of the control plane on this Mac (#4257): the web
/// page this Mac serves cannot stop its own control plane or change this Mac's launch agents,
/// so it asks with `control/connectAnother`, the control plane tells the person's windows
/// `control/connectWanted`, and the window whose Mac runs it does what its own sheet does
/// (`ControlPlaneMove.connect`). The page has said what happens already. Each step, and why
/// it stopped, goes back as `control/connectReport`; after the last, this control plane stops.
@MainActor
enum ConnectAnotherWanted {
    typealias Words = ConnectAnother.Words

    private static var running = false

    static func heard(_ params: JSONValue?, on control: DaemonClient, model: AppModel) async {
        guard !running, let want = try? params?.decode(ConnectAnother.Request.self),
              let host = HostScenes.model, host.settings.role == .runHere, host.settings.movedTo == nil,
              host.pin?.namesAControlPlane != true,
              let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self),
              status.machineID == MachineID.current else { return }
        running = true
        defer { running = false }
        func report(_ report: ConnectAnother.Report) async {
            _ = try? await control.call(DaemonAPI.Method.controlConnectReport, report, returning: DaemonAPI.Empty.self)
        }
        do {
            let code: ControlCode
            if want.hosted == true {
                await report(.init(step: Words.signingInHere))
                switch ConnectAnother.answer(try await HostedSignIn.run()) {
                case .code(let made): code = made
                case .failed(let why): throw ControlPlaneMove.Failure(description: why)
                }
            } else {
                switch ConnectAnother.check(want.code ?? "") {
                case .success(let typed): code = typed
                case .failure(let refusal): throw ControlPlaneMove.Failure(description: refusal.words)
                }
            }
            try await ControlPlaneMove.connect(with: code, host: host, model: model) { step in
                Task { await report(.init(step: step)) }
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            await report(.init(problem: "The sign-in to agentloops.dev was cancelled on this Mac."))
        } catch {
            let why = (error as? ControlPlaneMove.Failure)?.description ?? (error as? MachinePin.Refused)?.words
                ?? PairingAttempt.sentence(for: error, device: "this Mac")
            await report(.init(problem: why))
        }
    }
}

/// The sign-in to agentloops.dev with no sheet to hold it: a web authentication session over
/// whichever window is in front, as the sheet's own does (#4228).
@MainActor
private final class HostedSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: (HostedSignIn, ASWebAuthenticationSession)?

    static func run() async throws -> URL {
        NSApp.activate()
        return try await withCheckedThrowingContinuation { continuation in
            let anchor = HostedSignIn()
            let session = ASWebAuthenticationSession(url: ConnectAnother.hostedURL,
                                                     callback: .customScheme(ConnectAnother.callbackScheme)) { url, error in
                Task { @MainActor in current = nil }
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = anchor
            current = (anchor, session)
            if !session.start() {
                current = nil
                continuation.resume(throwing: ControlPlaneMove.Failure(description: ConnectAnother.Words.hostedNoCode))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}
