import AgentsKitCore
import SwiftUI

/// Settings ▸ Agents ▸ Policy (#2957, FR-019 to FR-021, frames A and C): your layer of the
/// policy, in five sections, each row with the value that applies, its cap from a layer
/// above, and where it comes from. The machine resolves the layers (`policy/effective`) and
/// keeps your layer (`policy/yours`, `policy/setYours`); this pane draws and asks.
///
/// One view for the Mac's Settings pane and the Remote's (slice 6), which change every rule
/// (FR-027, #3344). The web page's is `Web/src/views/settings/AgentsPolicy.tsx`.
struct PolicyPane: View {
    /// The machine that keeps your layer (the Mac's own host), or nil while it can't be reached.
    let host: DaemonClient?
    /// Moves when the machine says a layer changed (`policy/effectiveChanged`).
    let revision: Int
    /// Opens Organisation Policy, where there is one to open.
    var openOrganisationPolicy: (() -> Void)?

    @State private var effective: DaemonAPI.EffectivePolicy?
    @State private var yours: DaemonAPI.YourPolicyState?
    @State private var problem: String?
    @State private var isSaving = false

    private struct Reload: Hashable {
        var connected: Bool
        var revision: Int
    }

    var body: some View {
        Form {
            if let effective {
                banner(effective)
                #if os(macOS)
                // Rules signed on another Mac (#3230): tier mac+web, so not on the Remote.
                if let untrusted = yours?.untrusted {
                    untrustedSection(untrusted)
                }
                #endif
                ForEach(PolicyLayersWords.Section.allCases, id: \.self) { section in
                    Section {
                        ForEach(PolicyLayersWords.rows(in: section)) { row in
                            PolicyRuleRow(row: row, rule: effective.rules.first { $0.rule == row.rule },
                                          yours: yours.flatMap { PolicyLayersWords.value($0.policy.rules, row.rule) },
                                          editable: yours != nil && !isSaving) { value in
                                Task { await save(row.rule, value) }
                            }
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if section == .tools {
                            Text(PolicyLayersWords.toolsFoot).appText(.fine).foregroundStyle(.secondary)
                        } else if section == .attention {
                            Text(PolicyLayersWords.foot).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    .paperListRow()
                }
            } else if let problem {
                Text(problem).appText(.supporting).tinted(.failure).paperListRow()
            } else {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: Reload(connected: host != nil, revision: revision)) { await load() }
        .refreshable { await load() }
    }

    private func banner(_ effective: DaemonAPI.EffectivePolicy) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(PolicyLayersWords.banner(effective),
                      icon: effective.organisation == nil ? "person" : OrgPolicyWords.symbol)
                    .appText(.reading).fontWeight(.semibold)
                if effective.organisation != nil {
                    if let openOrganisationPolicy {
                        Button(PolicyLayersWords.organisationTitle, action: openOrganisationPolicy)
                            .buttonStyle(.borderless)
                    }
                } else {
                    Text(PolicyLayersWords.foldersLine(effective.foldersWithRules.count))
                        .appText(.fine).foregroundStyle(.secondary)
                }
                if let behind = PolicyLayersWords.behindLine(effective.behind) {
                    Text(behind).appText(.fine).tinted(.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem).appText(.fine).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
        }
        .paperListRow()
    }

    /// The rules of a copy of your layer this Mac can't trust (#3230), and the person's choice:
    /// sign them with this Mac's person key, or set the copy aside. Nothing signs them without it.
    private func untrustedSection(_ copy: DaemonAPI.UntrustedYourPolicy) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(PolicyLayersWords.untrustedTitle, icon: "exclamationmark.shield")
                    .appText(.reading).fontWeight(.semibold).tinted(.warning)
                Text(PolicyLayersWords.untrustedLine(copy)).appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
                if copy.lines.isEmpty {
                    Text(PolicyLayersWords.untrustedNone).appText(.fine).foregroundStyle(.secondary)
                } else {
                    ForEach(copy.lines, id: \.rule) { line in
                        Text("• " + PolicyLayersWords.untrustedRule(line)).appText(.fine)
                    }
                }
                HStack {
                    Button(PolicyLayersWords.signAgain) { Task { await settle(copy, sign: true) } }
                        .buttonStyle(.paperProminent)
                    Button(PolicyLayersWords.setAside) { Task { await settle(copy, sign: false) } }
                }
                .disabled(isSaving)
            }
            .accessibilityElement(children: .contain)
        }
        .paperListRow()
    }

    private func load() async {
        guard let host else {
            problem = "This Mac’s host can’t be reached."
            return
        }
        do {
            effective = try await host.call(DaemonAPI.Method.policyEffective, DaemonAPI.PolicyEffectiveRequest(),
                                            returning: DaemonAPI.EffectivePolicy.self)
            yours = try await host.call(DaemonAPI.Method.policyYours, DaemonAPI.Empty(),
                                        returning: DaemonAPI.YourPolicyState.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    private func save(_ rule: String, _ value: JSONValue?) async {
        guard let host, let yours else { return }
        isSaving = true
        defer { isSaving = false }
        let rules = PolicyLayersWords.setting(yours.policy.rules, rule, to: value)
        do {
            _ = try await host.call(DaemonAPI.Method.policySetYours,
                                    DaemonAPI.SetYourPolicyRequest(rules: rules, revision: yours.policy.revision),
                                    returning: DaemonAPI.YourPolicy.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await load()
    }

    private func settle(_ copy: DaemonAPI.UntrustedYourPolicy, sign: Bool) async {
        guard let host, let yours else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await host.call(DaemonAPI.Method.policySettleUntrustedYours,
                                    DaemonAPI.SettleUntrustedYourPolicyRequest(file: copy.file, revision: yours.policy.revision,
                                                                               sign: sign),
                                    returning: DaemonAPI.YourPolicyState.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await load()
    }
}
