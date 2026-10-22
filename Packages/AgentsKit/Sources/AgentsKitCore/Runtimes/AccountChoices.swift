import Foundation

/// A runtime's accounts as the account picker and **Reaches the Model By** list them (#840,
/// #999): its own sign-in, the accounts the person added, and the organisation's. The window
/// and the Remote both go by it; `Web/src/model/runtimes.ts` `accountChoices` says the same.
///
/// A picker keeps a choice as an account id: nil is the runtime's account for new sessions
/// (the default), `default` its own sign-in, any other id that account.
public struct AccountChoices: Sendable {
    public let runtimeID: String
    /// The runtime's accounts: the ones added, then the organisation's.
    public let accounts: [AccountProfile]
    public let policy: DaemonAPI.OrgPolicy?

    public init(runtimeID: String, profiles: [AccountProfile], policy: DaemonAPI.OrgPolicy? = nil) {
        self.runtimeID = runtimeID
        self.accounts = profiles.on(runtimeID)
        self.policy = policy
    }

    /// Whether the picker shows: the runtime has an account beside its own sign-in, an org
    /// account included (spec FR-023).
    public var shows: Bool { !accounts.isEmpty }

    /// The runtime's account for new sessions; nil for its own sign-in.
    public var defaultAccount: AccountProfile? { accounts.defaultAccount(runtimeID) }

    /// The account a choice means; nil for the runtime's own sign-in.
    public func account(for chosen: String?) -> AccountProfile? {
        guard let chosen else { return defaultAccount }
        if chosen == AccountProfile.ownSignInID { return nil }
        return accounts.first { $0.id == chosen } ?? defaultAccount
    }

    /// The name the picker's capsule shows for a choice.
    public func name(_ chosen: String?) -> String {
        account(for: chosen)?.name ?? AccountProfile.defaultName
    }

    /// The choice that picks the runtime's own sign-in: nil while it is the default, so a
    /// host that has no default account is never sent `default`.
    public var ownChoice: String? { defaultAccount == nil ? nil : AccountProfile.ownSignInID }

    /// What a start sends for a choice: an account the runtime has, `default`, or nil.
    public func sent(_ chosen: String?) -> String? {
        guard let chosen else { return nil }
        if chosen == AccountProfile.ownSignInID { return ownChoice }
        return accounts.contains { $0.id == chosen } ? chosen : nil
    }

    /// The organisation's mark on the runtime's own sign-in, when its policy refuses it
    /// (`runtimes.<id>.reach` without `signIn`, spec FR-024).
    public var ownSetBy: DaemonAPI.PolicySetBy? {
        guard let reach = policy?.runtimes?[runtimeID]?.reach, !reach.contains("signIn") else { return nil }
        let route = (defaultAccount ?? accounts.first { $0.isOrganisation && $0.setBy == nil })?.name
        let words = route.map { OrgAccountWords.requires(runtime: runtimeID, route: $0) } ?? OrgAccountWords.routeMissing
        return DaemonAPI.PolicySetBy(rule: "runtimes.\(runtimeID).reach", words: words)
    }

    /// Why a session on `accountID` (nil: the runtime's own sign-in) can no longer reach the
    /// model, for the strip over its chat with **Continue in New** (#999): the organisation
    /// removed its account, or its policy refuses it now. Nil when it can, or when the
    /// accounts have not been read yet (`loaded`), so nothing is said on a guess.
    public func moveReason(accountID: String?, loaded: Bool) -> String? {
        guard loaded else { return nil }
        guard let accountID else { return ownSetBy?.words }
        if let account = accounts.first(where: { $0.id == accountID }) { return account.setBy?.words }
        return accountID.hasPrefix("org:") ? OrgAccountWords.routeRemoved("this way to the model") : nil
    }
}
