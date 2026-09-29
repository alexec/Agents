import AgentsKit
import SwiftUI

/// Every runtime on this Mac and where its allowance stands (065, US4).
///
/// A page like Resources, reached from the foot of the sidebar. It was in Settings ▸
/// Agent Runtimes, which is where a control belongs; what it says is the state of the
/// machine, and it changes without anybody touching a setting. Settings keeps what
/// changes the Mac: installing a runtime, signing one in, its permission mode.
///
/// Every runtime the app knows is here, installed or not, so the page answers "what can
/// I start on" in one place. A runtime with no allowance of its own says so rather than
/// being left out, and one that is not on the Mac says what stopped it. **Mark available**
/// is the only thing here that changes anything, and a wrong mark costs one refused turn
/// (FR-023), so it asks nothing first.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What each runtime can be started on right now. An allowance that is "
                     + "spent is not a fault: a chat on it still takes a message, and the "
                     + "runtime says no until its plan comes back.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(runtimes.enumerated()), id: \.element.id) { index, status in
                        if index > 0 { Divider().padding(.leading, 14) }
                        RuntimeStatusRow(status: status,
                                         allowance: allowance(for: status.id),
                                         at: model.runtimeAllowances?.at ?? Date())
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Runtimes")
        .overlay {
            if runtimes.isEmpty {
                Text("No runtimes known yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.refreshRuntimes()
            await model.refreshRuntimeAllowances()
        }
    }

    /// Every runtime the app knows, in its own order. The daemon sends the whole list
    /// whether or not a runtime is on this Mac, so a missing one is here to be read
    /// rather than guessed at from the absence of a row.
    private var runtimes: [RuntimeStatus] { model.runtimes }

    /// The allowance row for a runtime, which is per credential: a runtime with a key of
    /// its own has more than one. The first is the runtime's own sign-in, which is the
    /// one a new agent would use.
    private func allowance(for runtimeID: String) -> RuntimeAllowances.Row? {
        model.runtimeAllowances?.rows.first { $0.runtimeID == runtimeID }
    }
}

/// One runtime: its name, what is true of it, and **Mark available** when it is out.
private struct RuntimeStatusRow: View {
    @Environment(AppModel.self) private var model
    let status: RuntimeStatus
    let allowance: RuntimeAllowances.Row?
    let at: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(status.runtime.name)
                    .fontWeight(.semibold)
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
                if let reading, allowance?.unusable == nil {
                    Text(reading)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isOut, let allowance {
                Button("Mark available") {
                    Task { await model.markRuntimeAvailable(allowance.credentialKey) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The allowance's own words where it has one, and the runtime's otherwise. What is
    /// not on this Mac is not an allowance state, so it is said in the runtime's terms.
    /// The install row keeps the size of a download and the buttons; this says what is.
    private var line: String {
        // A runtime the daemon found but nothing can start is that, whatever its plan
        // says. "Available" on a binary that is not here would be true of nothing.
        if let unusable = allowance?.unusable { return "Not usable: \(unusable)" }
        if let allowance { return allowance.line(now: at) }
        switch status.availability {
        case .available: return "Available · no plan of its own"
        case .missing: return "Not on this Mac"
        case .needsSignIn, .failed: return status.unavailableReason ?? "Can’t be used"
        case .installing(let progress): return progress.map { "\($0)…" } ?? "Starting…"
        case .installFailed(let reason): return reason
        }
    }

    private var reading: String? {
        PoolWords.reading(allowance?.state.reading, now: at)
    }

    /// Out, and usable enough to say so. A runtime that cannot be started at all is a
    /// different thing, and marking it available would only hide that.
    private var isOut: Bool { allowance?.state.isOut == true && allowance?.unusable == nil }
}

/// The foot of the sidebar's way into Runtimes (065). It says how many are out, which is
/// the only reason to come here, and a red dot beside it for the same reason. Nothing
/// when none are: an empty line is not a thing to keep up to date.
struct RuntimesRow: View {
    @Environment(AppModel.self) private var model

    private var outCount: Int {
        model.runtimeAllowances?.rows.filter { $0.state.isOut }.count ?? 0
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Runtimes", systemImage: "cpu")
            Spacer()
            if outCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                    Text("\(outCount) out").monospacedDigit()
                }
                .appText(.fine)
                .foregroundStyle(.secondary)
            }
        }
        .help("What each runtime can be started on right now, and where its allowance stands")
    }
}
