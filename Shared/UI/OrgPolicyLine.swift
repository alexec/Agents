import AgentsKitCore
import SwiftUI

/// The line on a choice a policy refuses or caps (#998, spec 998 FR-020): **Set by your
/// organisation** (or **Set by you**, **Set by this folder**: the layer that decided, #3150), and the rule's words in a help tip on the Mac or a detail line on
/// the Remote. The choice itself is shown, dimmed, never hidden (US3 scenario 1). The web page's is
/// `Web/src/views/OrgPolicyLine.tsx`.
struct OrgPolicyLine: View {
    let mark: DaemonAPI.PolicySetBy

    var body: some View {
        #if os(macOS)
        Label(mark.title, systemImage: mark.symbol)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .help(mark.words)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OrgPolicyWords.line(mark))
        #else
        VStack(alignment: .leading, spacing: 1) {
            Label(mark.title, systemImage: mark.symbol)
            Text(mark.words).fixedSize(horizontal: false, vertical: true)
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OrgPolicyWords.line(mark))
        #endif
    }
}

/// The line for a refused call (`policyRefused`, FR-010): the refusal's title and words, in the
/// failure's colour where a call failed rather than a choice being shown.
struct OrgPolicyRefusalLine: View {
    let refusal: DaemonAPI.PolicyRefusal

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = refusal.title {
                Label(title, systemImage: refusal.symbol).bold()
            }
            Text(refusal.words).fixedSize(horizontal: false, vertical: true)
        }
        .appText(.supporting)
        .accessibilityElement(children: .combine)
    }
}

/// A menu's line for a choice the policy refuses: its name, disabled, with **Set by your
/// organisation** and the rule as the item's second line (a menu has no tips).
struct OrgPolicyMenuItem: View {
    let name: String
    let mark: DaemonAPI.PolicySetBy

    var body: some View {
        Button {} label: {
            Text(name)
            Text(OrgPolicyWords.line(mark))
        }
        .disabled(true)
    }
}

/// The neutral banner (#4737) on every screen while this machine starts no work for its
/// organisation (#998, US5 scenario 2): the kill switch, with who turned it on and when, or the
/// machine's own reason (no policy it can trust, an update it needs). Nothing otherwise.
struct OrgPolicyStrip: View {
    let state: DaemonAPI.PolicyState?

    var body: some View {
        // A neutral banner (#4737): set by the organisation, nothing for the person to do here.
        if let state, state.startsNothing, let line = Self.line(state) {
            PaneBanner(tone: .neutral, symbol: "building.2", line, detail: Self.detail(state))
                .paneBannerInset()
        }
    }

    private static func line(_ state: DaemonAPI.PolicyState) -> String? {
        if state.stopAll { return OrgPolicyWords.stoppedStrip }
        return state.refusal?.line
    }

    private static func detail(_ state: DaemonAPI.PolicyState) -> String? {
        guard state.stopAll, let stop = state.policy?.stopAll, stop.on else { return nil }
        return [OrgPolicyWords.stoppedBy(stop), stop.note].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
    }
}

/// The organisation's budgets beside the person's own limits on Cost (#998, FR-016), read only:
/// each limit in force is the lower of the two. Nothing with no budget.
struct OrgBudgetRows: View {
    let state: DaemonAPI.CostState?

    var body: some View {
        let rows = OrgPolicyWords.budgetRows(state?.organisation)
        if !rows.isEmpty {
            ForEach(rows) { row in
                LabeledContent(row.title) { Text(row.words).monospacedDigit() }
            }
            OrgPolicyLine(mark: state?.setBy ?? DaemonAPI.PolicySetBy(rule: "budgets", words: OrgPolicyWords.budgetFoot))
        }
    }
}

/// The person's own pass-through names for one runtime (#998, FR-011a), read only: each one the
/// policy does not allow is dimmed, with why, and is not passed. Nothing with none.
struct PassThroughRows: View {
    let names: [DaemonAPI.PassThroughName]

    var body: some View {
        ForEach(names) { name in
            VStack(alignment: .leading, spacing: 2) {
                Text(name.name).appText(.code)
                    .foregroundStyle(name.setBy == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if let mark = name.setBy { OrgPolicyLine(mark: mark) }
            }
        }
    }
}

extension EnvironmentValues {
    /// The organisation's mark while its policy requires the command sandbox (#998), for the
    /// sandbox failure card deep in the transcript: **Continue without sandbox** is not offered.
    @Entry var orgSandboxSetBy: DaemonAPI.PolicySetBy?
}

extension View {
    /// Dims and disables a choice the policy refuses, with the rule as its tip (#998, FR-020).
    /// Nothing changes without a mark.
    @ViewBuilder
    func setByOrganisation(_ mark: DaemonAPI.PolicySetBy?) -> some View {
        if let mark {
            disabled(true)
                .opacity(0.5)
                .help(OrgPolicyWords.line(mark))
        } else {
            self
        }
    }
}
