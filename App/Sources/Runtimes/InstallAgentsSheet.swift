import AgentsKit
import SwiftUI

/// Offered once at start-up when an agent is missing (048): every agent the app knows,
/// what is here, and a button for what is not.
///
/// Once per missing agent, not once per launch: "Not now" is remembered for the agents
/// missing at the time, and the sheet comes back only for one that has not been offered
/// yet. Settings ▸ Agent Runtimes has the same list for any time after.
struct InstallAgentsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaperSheet(title: "Install your agents") {
            Text(summary)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.runtimes) { status in
                    RuntimeInstallRow(status: status)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        } actions: {
            Button("Not now") { model.rememberInstallOffer() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { model.rememberInstallOffer() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 480)
    }

    /// Names what is missing rather than saying "these" over a list that also has the
    /// ones already here, ticked.
    private var summary: String {
        let missing = model.missingRuntimes.map(\.runtime.name)
        let lead = "Agents runs the coding CLIs on this Mac."
        guard let names = ListFormatter.localizedString(byJoining: missing).nilIfEmpty else {
            return "\(lead) Everything it knows is here."
        }
        let verb = missing.count == 1 ? "isn’t" : "aren’t"
        let them = missing.count == 1 ? "it" : "them"
        return "\(lead) \(names) \(verb) here yet. Install \(them) now, or later from Settings ▸ Agent Runtimes."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One agent: here or not here, being installed, or a way to get it. The same row in the
/// sheet, in Settings ▸ Agent Runtimes and under an empty project list.
///
/// Laid out the way an `AgentRow` is: the state as an icon on the left, the name on the
/// top line and where it stands on the line under it, so this list reads like every
/// other list of things in the app. A runtime that is here says nothing further: which
/// binary it is, and where that binary sits, is the app's business and not the reader's.
struct RuntimeInstallRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let status: RuntimeStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RuntimeStatusIcon(availability: status.availability)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.runtime.name)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                detail
            }
            Spacer(minLength: 12)
            actions
        }
    }

    @ViewBuilder private var detail: some View {
        switch status.availability {
        case .available:
            // Nothing: where the binary sits is the app's business, and the tick beside
            // the name already says it is here.
            EmptyView()
        case .installing(let progress):
            Text(progress.map { "\($0)…" } ?? "Starting…")
                .appText(.supporting).foregroundStyle(.secondary)
                .lineLimit(1)
        case .installFailed(let reason):
            Text(reason).appText(.supporting).tinted(.failure)
                .fixedSize(horizontal: false, vertical: true)
        case .missing:
            Text(Self.downloadNote(for: status.runtime.id).map { "Not on this Mac · \($0)" } ?? "Not on this Mac")
                .appText(.supporting).foregroundStyle(.secondary)
                .lineLimit(1)
        case .needsSignIn, .failed:
            Text(status.unavailableReason ?? "Can’t be used")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch status.availability {
        case .missing:
            if status.runtime.install != nil {
                Button("Install") { install() }
                    .help("Install \(status.runtime.name) on this Mac")
            } else {
                pageButton
            }
        case .installFailed:
            HStack {
                pageButton
                if status.runtime.install != nil {
                    Button("Retry") { install() }
                        .help("Try installing \(status.runtime.name) again")
                }
            }
        case .available where status.outdated && status.runtime.install != nil:
            // This app carries a newer pin than the one installed (047). Agents already
            // running keep the old one until they end.
            Button("Update") { install() }
                .help("Install the \(status.runtime.name) this version of Agents carries. Agents already running keep theirs.")
        default:
            EmptyView()
        }
    }

    private var pageButton: some View {
        Button("Open install page") { openURL(status.runtime.installPage) }
            .help(status.runtime.installPage.absoluteString)
    }

    private func install() {
        Task { await model.installRuntime(status.id) }
    }

    /// "112 MB from Google", said before **Install** for a runtime the app downloads from
    /// its vendor as one archive (049), so a large download is not a surprise. From the
    /// manifest the app carries; nil for everything else.
    static func downloadNote(for runtimeID: String) -> String? {
        guard let archive = bundledArchives[runtimeID],
              let platform = archive.manifest.platforms[archive.macPlatformKey],
              platform.knownBroken == nil else { return nil }
        return "\(ArchiveToolset.megabytes(platform.size)) from \(ArchiveToolset.vendor(of: archive))"
    }

    private static let bundledArchives: [String: ArchiveToolset] = Bundle.main
        .url(forResource: "toolsets", withExtension: nil)
        .map(ArchiveToolset.loadAll(from:)) ?? [:]
}

/// An agent's state as the icon beside its name: the same 18-point well and glyph size
/// as an agent's `StatusIcon`, and the same spinner while something is under way.
/// Only a failure is coloured; being here or not here yet is not news that needs it.
private struct RuntimeStatusIcon: View {
    let availability: RuntimeAvailability

    var body: some View {
        Group {
            if availability.isInstalling {
                // The agent's row, at the same size, so a list of installs turns with it.
                SyncedSpinner(diameter: 12)
            } else {
                Image(systemName: symbol)
                    // Decorative: the row's status glyph, held to its 18-point frame.
                    .font(.system(size: 15))
                    .foregroundStyle(tint.style(or: .secondary))
            }
        }
        .frame(width: 18, height: 18)
        .help(label)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch availability {
        case .available: "checkmark.circle"
        case .missing, .installing: "circle.dashed"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .failed, .installFailed: "exclamationmark.triangle"
        }
    }

    private var tint: StateTint {
        switch availability {
        case .needsSignIn, .failed, .installFailed: .failure
        case .available, .missing, .installing: .none
        }
    }

    private var label: String {
        switch availability {
        case .available: "Installed"
        case .missing: "Not installed"
        case .installing: "Installing"
        case .needsSignIn: "Signed out"
        case .failed: "Can’t be used"
        case .installFailed: "Install failed"
        }
    }
}

/// Which missing agents the start-up sheet has already offered (048). Scoped by root the
/// way drafts and the appearance are: every copy of the app shares one defaults domain,
/// and a scratch copy offering its own agents must not silence the real app's sheet.
enum InstallOffer {
    static var defaultsKey: String {
        let locations = StoreLocations.default
        return locations.isStandard ? "installOffered" : "installOffered.root:\(locations.name)"
    }

    static var offered: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    static func remember(_ ids: [String]) {
        UserDefaults.standard.set(Array(offered.union(ids)).sorted(), forKey: defaultsKey)
    }

    /// Not here, or not here yet: what the sheet is for. Signed out is here.
    static func isMissing(_ availability: RuntimeAvailability) -> Bool {
        switch availability {
        case .missing, .installing, .installFailed: true
        case .available, .needsSignIn, .failed: false
        }
    }
}
