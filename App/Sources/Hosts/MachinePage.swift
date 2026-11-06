import AgentsKitCore
import SwiftUI

/// One machine's page in the main window (#3626): the place to go for its status. Its CPU
/// and memory now, every disk its agents write to with the level the disk-low strip uses,
/// and its processes (#3453). Read with `machine/usage` when it opens and every few seconds
/// while it is open, never otherwise. The machine's settings stay in Settings ▸ Machines;
/// Settings… goes there. The web page draws the same in Web/src/views/MachinePage.tsx.
struct MachinePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let host: MachineRef

    @State private var usage: DaemonAPI.MachineUsageState?
    @State private var failure: String?

    private var name: String { model.hosts.label(host) }
    private var offline: Bool { model.hosts.isOffline(host) }
    private var answersUsage: Bool { model.host(host, has: Capability.machineUsage1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).appText(.reading)
                    Text(offline ? "Offline" : "Online")
                        .appText(.supporting)
                        .foregroundStyle(offline ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                Button("Settings…") {
                    model.settingsMachineAsked = host
                    model.settingsPaneAsked = .machines
                    openSettings()
                }
                .help("\(name)’s sleep, backups and desktop control, in Settings ▸ Machines")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Form {
                if offline {
                    Section {
                        Text("\(name) is offline, so it can’t say how it is doing now.")
                            .foregroundStyle(.secondary)
                    }
                } else if !answersUsage {
                    Section {
                        Text("Update Agents on \(name) to see its CPU, memory and disks here.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    usageSection
                    disksSection
                }
                if !offline, model.host(host, has: Capability.processes1) {
                    MachineProcessesSection(client: model.client(for: host), hostName: name, showsTotals: false)
                }
            }
            .paperForm()
        }
        .navigationTitle(name)
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

    @ViewBuilder
    private var usageSection: some View {
        Section("Usage") {
            if let usage {
                LabeledContent("CPU", value: ProcessWords.machineCPU(usage.machine))
                LabeledContent("Memory", value: ProcessWords.machineMemory(usage.machine))
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var disksSection: some View {
        if let usage {
            Section {
                if usage.disks.isEmpty {
                    Text("No disk looked at yet. \(name) looks every minute.").foregroundStyle(.secondary)
                }
                ForEach(usage.disks) { disk in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(DiskSpace.freeWords(disk.reading)).monospacedDigit().fixedSize()
                            Text(DiskSpace.levelWords(disk.level))
                                .foregroundStyle(Self.tint(disk.level).style(or: .secondary))
                        }
                    } label: {
                        Text(disk.reading.volume)
                        Text(disk.reading.mount)
                    }
                    .help(disk.level == .ok ? disk.reading.mount : disk.line)
                }
            } header: {
                Text("Disks")
            } footer: {
                Text("Each disk its agents write to. Low and almost full are the lines the disk-low warning uses.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func tint(_ level: DiskLevel) -> StateTint {
        switch level {
        case .ok: .none
        case .low: .attention
        case .critical: .failure
        }
    }

    private func read() async {
        do {
            usage = try await model.client(for: host).call(DaemonAPI.Method.machineUsage, DaemonAPI.Empty(),
                                                             returning: DaemonAPI.MachineUsageState.self)
            failure = nil
        } catch let error as JSONRPCError {
            failure = error.message
        } catch {
            failure = "\(name) can’t be asked now: \(error.localizedDescription)"
        }
    }
}

/// A machine's row under Machines in the sidebar (#3626): its name, and offline when it is.
struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    var body: some View {
        let name = model.hosts.label(host)
        let offline = model.hosts.isOffline(host)
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.primary).lineLimit(1)
            Spacer()
            if offline {
                Text("Offline").appText(.fine).foregroundStyle(.secondary)
            }
        }
        .help(model.diskWarns(host) ? "\(name): a disk is low. Its CPU, memory and disks"
            : "\(name): its CPU, memory and disks")
        .accessibilityValue(offline ? "Offline" : "")
    }
}

extension AppModel {
    /// Whether a disk on the machine is low or almost full, as its disk-low strip says (#3626).
    func diskWarns(_ host: MachineRef) -> Bool {
        let alarms = host == .mac ? work.disk.alarms : serverDisks[host]?.alarms ?? []
        return alarms.contains { $0.level != .ok }
    }
}
