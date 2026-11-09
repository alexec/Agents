import AgentsKitCore
import SwiftUI

/// One machine's page (#4034), as the window's (#3626) and the web page's: a summary first,
/// its CPU, memory and worst disk on one line (#3743), then its disks, then the runtimes
/// installed there (#3629), with Sign In… and Update (#4035). Read with `machine/usage` as it opens and every few seconds while
/// it is open, never otherwise. Its worktrees, resources and processes, and its settings,
/// stay on the Mac and the web page.
struct RemoteMachinePage: View {
    @Environment(RemoteModel.self) private var model
    let host: MachineRef

    @State private var usage: DaemonAPI.MachineUsageState?
    @State private var failure: String?
    /// The runtime whose Sign In… is open.
    @State private var signingIn: Runtime?

    private var name: String { model.machineName(host) }
    private var offline: Bool { model.machineOffline(host) }
    private var answersUsage: Bool { model.host(host, has: Capability.machineUsage1) }

    var body: some View {
        let row = model.machineRow(host)
        let words = model.need(of: host).map { MachineNeedWords.line($0, name: name, row: row) }
        List {
            Section {
                Text(words ?? (offline ? "Offline" : "Online"))
                    .foregroundStyle(offline ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                if offline {
                    Text("\(name) is offline, so it can’t say how it is doing now.").foregroundStyle(.secondary)
                } else if !answersUsage {
                    Text("Update Agents on \(name) to see its CPU, memory and disks here.").foregroundStyle(.secondary)
                } else if let usage {
                    summary(usage)
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            if !offline, let usage {
                Section("Disks") {
                    if usage.disks.isEmpty {
                        Text("No disk looked at yet. \(name) looks every minute.").foregroundStyle(.secondary)
                    }
                    ForEach(usage.disks.sorted { $0.level > $1.level }) { disk in
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(DiskSpace.freeWords(disk.reading)).monospacedDigit()
                                Text(DiskSpace.levelWords(disk.level))
                                    .foregroundStyle(Self.tint(disk.level).style(or: .secondary))
                            }
                        } label: {
                            Text(disk.reading.volume)
                        }
                    }
                }
            }
            if !offline {
                Section("Runtimes") {
                    let runtimes = model.runtimes(on: host).filter(\.isInstalled)
                    if runtimes.isEmpty {
                        Text("None installed here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(runtimes) { status in runtimeRow(status) }
                }
            }
        }
        .appText(.supporting)
        .navigationTitle(name)
        .task(id: host) {
            await model.refreshMachineRuntimes(host)
            // A tap on a row that says a runtime needs sign-in comes here: Sign In… opens (#4035).
            if case .signIn = model.need(of: host), let first = model.runtimes(on: host).first(where: offersSignIn) {
                signingIn = first.runtime
            }
        }
        .sheet(item: $signingIn) { runtime in
            RuntimeSignInSheet(host: host, runtime: runtime)
        }
        .task(id: host) {
            usage = nil
            failure = nil
            guard answersUsage else { return }
            while !Task.isCancelled {
                if !offline { await read() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// A runtime's line (#3629), with **Sign In…** on a server's Claude or Codex that is not
    /// signed in, and **Update** when the app carries a newer copy (#4035), as the window's and
    /// the web page's. This Mac's runtimes sign in on the Mac, which the line says.
    private func runtimeRow(_ status: RuntimeStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.runtime.name)
                Text(status.machineLine).appText(.fine).foregroundStyle(.secondary)
                if host == .mac, status.needsSignIn {
                    Text(RuntimeSignInWords.onTheMac).appText(.fine).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            let update = status.outdated && status.runtime.install != nil && !status.availability.isInstalling
            if offersSignIn(status) || update {
                HStack(spacing: 8) {
                    if offersSignIn(status) {
                        Button("Sign In…") { signingIn = status.runtime }
                    }
                    if update {
                        Button("Update") { Task { await model.updateRuntime(status.id, on: host) } }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Whether Sign In… is offered here: a server's Claude or Codex, not signed in, on a machine
    /// that signs in from a client (#3349). This Mac's daemon refuses it.
    private func offersSignIn(_ status: RuntimeStatus) -> Bool {
        host != .mac && status.signIn != nil && status.needsSignIn && model.host(host, has: Capability.runtimesSignIn1)
    }

    /// "Is this machine OK?" in one line (#3743): CPU, memory and the worst disk, in its tint.
    private func summary(_ usage: DaemonAPI.MachineUsageState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CPU \(ProcessWords.machineCPU(usage.machine)) · Memory \(ProcessWords.machineMemory(usage.machine))")
            if let disk = DiskSpace.headline(usage.disks, folders: []) {
                Text(DiskSpace.summaryWords(disk)).foregroundStyle(Self.tint(disk.level).style(or: .primary))
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private static func tint(_ level: DiskLevel) -> StateTint {
        switch level {
        case .ok: .none
        case .low: .attention
        case .critical: .failure
        }
    }

    private func read() async {
        do {
            usage = try await model.machineUsage(host)
            failure = nil
        } catch let error as JSONRPCError {
            failure = error.message
        } catch {
            failure = "\(name) can’t be asked now: \(error.localizedDescription)"
        }
    }
}
