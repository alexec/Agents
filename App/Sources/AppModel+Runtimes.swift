import AgentsKitCore
import AppKit
import Foundation
import os

/// Runtimes.
extension AppModel {
    // MARK: Runtimes

    /// Sign the runtime in, or one of its added accounts (#840) when `accountID` is set.
    func signIn(runtimeID: String, methodID: String, accountID: String? = nil) async -> String? {
        do {
            let account = try await macClient.call(DaemonAPI.Method.runtimeAuthenticate,
                                                DaemonAPI.AuthenticateRequest(runtimeID: runtimeID,
                                                                              methodID: methodID, accountID: accountID),
                                                returning: RuntimeAccount.self)
            if accountID == nil { accounts[runtimeID] = account }
            await refreshRuntimes()
            if accountID != nil { await refreshAccountProfiles() }
            return nil
        } catch let error as JSONRPCError {
            // A method that needs a terminal comes back as the command to run, which is
            // the runtime's own advice rather than ours.
            if let command = error.data?["command"]?.stringValue { return command }
            problem = describe(error)
            return nil
        } catch {
            problem = describe(error)
            return nil
        }
    }

    func signOut(runtimeID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeLogOut,
                                           DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                           returning: [UUID].self)
        }
        await refreshAccounts()
        await refreshAgents()
    }

    func setProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeSetProvider,
                                           DaemonAPI.SetProviderRequest(runtimeID: runtimeID,
                                                                        providerID: providerID),
                                           returning: RuntimeAccount.self)
        }
        await refreshAccounts()
    }

    func disableProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeDisableProvider,
                                           DaemonAPI.SetProviderRequest(runtimeID: runtimeID,
                                                                        providerID: providerID),
                                           returning: RuntimeAccount.self)
        }
        await refreshAccounts()
    }

    /// Which agents a sign-out would stop, so the user is told before it happens.
    func agentsHolding(runtimeID: String) -> [Agent] {
        agents.filter { $0.runtimeID == runtimeID && $0.state.holdsRuntime }
    }
}
