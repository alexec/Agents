import Foundation

/// The words of an added account (#840) that the Mac and the Remote both say (#2255, #2264,
/// #2265). `Web/src/model/runtimes.ts` says the same on the web page.
public enum AccountWords {
    /// Where an added account is signed in: the Mac's Runtimes page (#2255).
    public static let signInOnTheMac = "Sign it in on the Mac, in Runtimes."

    /// What Remove does, under its question: how many sessions it stops, and that it cannot be
    /// undone (#2264). `place` is where the sign-in is, such as "this Mac" or "the Mac".
    public static func removeMessage(stopping count: Int, from place: String) -> String {
        let stops = count == 0 ? "Nothing is running on it."
            : "This stops \(count) session\(count == 1 ? "" : "s") mid-conversation."
        return "\(stops) Its sign-in is deleted from \(place). This can’t be undone."
    }

    /// The line under a choice of account when a session starts (#2265): why it cannot be used,
    /// or that its allowance is out, else who it is. `account` nil is the runtime's own sign-in;
    /// `row` is its allowance row.
    public static func choiceNote(_ account: AccountProfile?, row: RuntimeAllowances.Row?, now: Date) -> String? {
        if let account, !account.signedIn, !account.isOrganisation { return account.state }
        let fallback = account?.isOrganisation == true ? account?.state : account?.signedInAs
        guard let row else { return fallback }
        if let unusable = row.unusable { return "Not usable: \(unusable)" }
        return row.state.isOut ? row.memberLine(now: now) : fallback
    }
}
