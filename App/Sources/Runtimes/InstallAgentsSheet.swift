import AgentsKit
import SwiftUI

/// Offered once at start-up when an agent is missing (048): every agent the app knows,
/// what is here, and a button for what is not.
///
/// Once per missing agent, not once per launch: "Not now" is remembered for the agents
/// missing at the time, and the sheet comes back only for one that has not been offered
/// yet. Settings ▸ Agents has the same list for any time after.
struct InstallAgentsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install your agents").appText(.reading).fontWeight(.semibold)
            Text("Agents runs the coding CLIs on this Mac. These aren’t here yet. "
                 + "Install them now, or later from Settings ▸ Agents.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.runtimes) { status in
                    RuntimeInstallRow(status: status)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Not now") { model.rememberInstallOffer() }
                Button("Done") { model.rememberInstallOffer() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// One agent: here and where, being installed, or a way to get it. The same row in the
/// sheet, in Settings ▸ Agents and under an empty project list.
struct RuntimeInstallRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let status: RuntimeStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.runtime.name).appText(.reading).fontWeight(.medium)
                detail
            }
            Spacer(minLength: 12)
            actions
        }
    }

    @ViewBuilder private var detail: some View {
        switch status.availability {
        case .available(let path, _):
            Label(path, systemImage: "checkmark")
                .appText(.fine).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .installing(let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress.map { "\($0)…" } ?? "Starting…").appText(.fine).foregroundStyle(.secondary)
            }
        case .installFailed(let reason):
            Text(reason).appText(.fine).tinted(.failure)
                .fixedSize(horizontal: false, vertical: true)
        case .missing:
            Text("Not on this Mac").appText(.fine).foregroundStyle(.secondary)
        case .needsSignIn, .failed:
            if let reason = status.unavailableReason {
                Text(reason).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch status.availability {
        case .missing:
            if status.runtime.install != nil {
                Button("Install") { install() }
            } else {
                pageButton
            }
        case .installFailed:
            HStack {
                pageButton
                if status.runtime.install != nil {
                    Button("Retry") { install() }
                }
            }
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
