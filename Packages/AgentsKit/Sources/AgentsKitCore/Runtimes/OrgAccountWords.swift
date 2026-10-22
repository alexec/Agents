import Foundation

/// The words of the organisation's ways to the model (#999, T029), on the Mac and the Remote
/// (`Web/src/model/orgAccounts.ts` says the same on the web page). A member sees a route's name,
/// its kind and **From your organisation**, never a value, a fingerprint, a region or an address
/// (spec FR-026).
public enum OrgAccountWords {
    /// The line under an org account, on every client.
    public static let fromOrganisation = "From your organisation"
    /// An org account's allowance: it has no plan reading (spec D12).
    public static let noPlanLimit = "Organisation · No plan limit"
    public static let routesTitle = "Your Organisation’s Ways to the Model"
    public static let noRoutes = "Your organisation gives you no key or gateway. Each runtime uses your own sign-in."
    public static let routesFoot = "Your organisation keeps the keys. No client shows them, and the runtime never has them: it reaches the model through a relay on your machine."

    /// What a kind is called.
    public static func kindName(_ kind: String) -> String {
        switch kind {
        case "key": "Org key"
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case "azure": "Microsoft Azure"
        case "baseURL": "Gateway"
        default: kind
        }
    }

    /// What a way to the model is called, in a policy.
    public static func reachName(_ reach: String) -> String {
        switch reach {
        case "signIn": "own sign-in"
        case "orgKey": "org key"
        case "gateway": "gateway"
        default: reach
        }
    }

    /// A runtime's `reach` rule in words: "Org key or gateway only".
    public static func reachWords(_ reach: [String]) -> String {
        let order = ["signIn", "orgKey", "gateway"]
        let ways = order.filter(Set(reach).contains)
        if ways.count == order.count { return "Any way" }
        let named = ways.map(reachName).joined(separator: " or ")
        return named.prefix(1).uppercased() + named.dropFirst() + " only"
    }

    /// "Acme Bedrock · Amazon Bedrock · Claude, OpenCode · default for Claude", a member's line.
    public static func mineLine(_ route: DaemonAPI.OrgRouteMine) -> String {
        var parts = [kindName(route.kind), route.runtimes.map(OrgPolicyWords.runtimeName).joined(separator: ", ")]
        if !route.defaultFor.isEmpty {
            parts.append("default for " + route.defaultFor.map(OrgPolicyWords.runtimeName).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // The refusals of the contract (contracts/org-routes-api.md), for the chat lines of slice 3.

    /// "Your organisation requires Claude to use Acme Bedrock."
    public static func requires(runtime: String, route: String) -> String {
        "Your organisation requires \(OrgPolicyWords.runtimeName(runtime)) to use \(route)."
    }

    public static let antigravityRefused = "Your organisation does not allow Antigravity, because of Google’s terms on third-party tools."
    public static let antigravityAccepted = "Your organisation has reviewed Google’s terms for Antigravity."
    public static let routeMissing = "Your organisation’s way to this model has not reached this machine. Connect to the network."

    /// "Your organisation removed Acme Bedrock."
    public static func routeRemoved(_ name: String) -> String {
        "Your organisation removed \(name)."
    }

    /// "Your organisation's Bedrock access ended while this machine is offline. Connect to the network."
    public static func routeExpired(kind: String) -> String {
        let short = switch kind {
        case "bedrock": "Bedrock"
        case "vertex": "Vertex AI"
        case "azure": "Azure"
        default: kindName(kind)
        }
        return "Your organisation’s \(short) access ended while this machine is offline. Connect to the network."
    }
}
