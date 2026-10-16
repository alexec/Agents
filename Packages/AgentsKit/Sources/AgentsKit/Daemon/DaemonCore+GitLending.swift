import AgentsKitCore
import Foundation

extension DaemonCore {
    /// `git/credential` (#1122): this Linux host's git, through `agentsd git-credential`,
    /// asking for the git access a Mac lends it. Only over this host's own socket (`peer`
    /// is the process that connected): never a channel the control plane opened, so no
    /// client reads a credential. Neither the credential nor anything of it is logged.
    func lentGitCredential(_ params: JSONValue?, peer: Int32?) async -> Result<JSONValue, JSONRPCError> {
        #if os(macOS)
        return .failure(JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "A Mac uses its own git access."))
        #else
        guard peer != nil else {
            return .failure(JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "Only this host's own git may ask that."))
        }
        guard let askControl else {
            return .failure(JSONRPCError(code: DaemonAPI.Failure.notSupported,
                                         message: "This host isn't on a control plane, so no Mac lends it git access."))
        }
        guard let request = try? params?.decode(DaemonAPI.GitCredentialRequest.self),
              request.protocol == "https", DaemonAPI.GitCredentialRequest.isServer(request.host) else {
            return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "Only https git access is lent."))
        }
        do {
            return .success(try await askControl(DaemonAPI.Method.gitCredential, try JSONValue.encoding(request)))
        } catch let error as JSONRPCError {
            DaemonLog.shared.write("git: no lent git access for \(request.host): \(error.message)")
            return .failure(error)
        } catch {
            return .failure(JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "This host can’t reach its control plane now."))
        }
        #endif
    }
}
