import AgentsKitCore
import AuthenticationServices
import SwiftUI

/// The client's half of a code-flow sign-in (#1343, Linear), the same on the Mac and the
/// Remote. The host made the verifier and the state and keeps them; this opens the authorize
/// address in an authentication session, which catches agents://oauth/callback when the
/// hand-back page (oauth.agentloops.dev/oauth/callback) sends the person there, and gives the
/// code and the state to the host. No token reaches this side.
enum CodeFlowSignIn {
    enum Outcome: Equatable {
        case connected(DaemonAPI.ConnectionSignIn)
        case cancelled
        case failed(String)
    }

    /// Why the host did not take the code, in words.
    struct Problem: Error, Equatable {
        var words: String
        init(_ words: String) { self.words = words }
    }

    @MainActor
    static func finish(_ flow: DaemonAPI.ConnectionSignIn, in session: WebAuthenticationSession,
                       complete: (DaemonAPI.ConnectionSignInCompleteRequest) async -> Result<DaemonAPI.ConnectionSignIn, Problem>)
        async -> Outcome {
        let name = ConnectorSetupWords.name(flow.provider)
        guard let address = URL(string: flow.verificationURL) else { return .failed("\(name) gave no address to open.") }
        let callback: URL
        do {
            callback = try await session.authenticate(
                using: address, callback: .customScheme(DaemonAPI.ConnectionSignInCompleteRequest.callbackScheme),
                preferredBrowserSession: nil, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let request = DaemonAPI.ConnectionSignInCompleteRequest(flowID: flow.flowID, callback: callback) else {
            return .failed("\(name) came back with no answer. Try again.")
        }
        switch await complete(request) {
        case .failure(let problem):
            return .failed(problem.words)
        case .success(let ended):
            switch ended.status {
            case .connected: return .connected(ended)
            case .cancelled: return .cancelled
            default: return .failed(ConnectorSetupWords.sheetStatus(ended))
            }
        }
    }
}
