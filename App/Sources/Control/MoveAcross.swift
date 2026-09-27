import AgentsKit
import AgentsKitCore
import SwiftUI

/// Moving today's set-up to a control plane on this Mac, once, when chosen (058, US6,
/// frame I). Nothing in the window's root moves; it becomes this Mac's host.
///
/// Until the window adopts the control plane, a failure leaves the old way working:
/// the window goes back to its own daemon, which is where everything still is (FR-025).
@MainActor
@Observable
final class MoveAcross {
    enum Phase: Equatable {
        case offer
        case moving(String)
        case done(failedServers: [String])
        case failed(String)
    }

    private(set) var phase: Phase = .offer
    let summary: ControlMove.Summary
    private let services = LocalServices.forThisWindow

    init() {
        summary = ControlMove.summary(of: StoreLocations.default)
    }

    func run(model: AppModel) async {
        let locations = StoreLocations.default
        do {
            phase = .moving("Setting up the control plane…")
            try ControlMove.prepare(control: services.controlRoot, from: locations)

            phase = .moving("Handing this Mac’s agents to the control plane…")
            // The window's own daemon lets go; launchd starts the host in its place, from
            // the same root. Agents mid-turn make it refuse, and nothing has changed yet.
            try await model.letTheOldDaemonGo()

            phase = .moving("Allowing Agents in the background…")
            switch await services.register() {
            case .enabled: break
            case .needsApproval:
                SMAppServiceOpener.openLoginItems()
                throw Failure("Allow Agents in System Settings ▸ Login Items, then try again.")
            case .failed(let why): throw Failure(why)
            }

            phase = .moving("Waiting for this Mac’s host…")
            let link = ControlConfig.link(root: services.controlRoot)
            let control = DaemonClient(link: link.controlLink)
            guard await Self.within(.seconds(60), {
                guard (try? await control.connect(startIfNeeded: false, timeout: .seconds(2))) != nil,
                      let hosts = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
                else { return false }
                return hosts.contains { $0.id == .mac && $0.state == "online" }
            }) else {
                throw Failure("This Mac’s host didn’t join the control plane. Its log is in \(services.controlRoot.path).")
            }

            // From here the window is the control plane's client.
            await model.adoptControlPlane(root: services.controlRoot)

            var failed: [String] = []
            for server in ControlMove.servers(of: locations) {
                phase = .moving("Adding \(server.label) as a host…")
                let answer = try? await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(["destination": .string(server.sshName)]))
                if answer?["host"] == nil { failed.append(server.label) }
            }
            try? ControlMove.retireServers(of: locations)
            await control.disconnect()
            link.disconnect()
            phase = .done(failedServers: failed)
        } catch {
            await model.resumeTheOldWay()
            phase = .failed("\(error)")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func within(_ limit: Duration, _ check: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

import ServiceManagement

enum SMAppServiceOpener {
    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// The strip that offers the move, never the move itself (frame I).
struct MoveAcrossStrip: View {
    @Environment(AppModel.self) private var model
    @State private var offering = false

    var body: some View {
        HStack {
            Text("Agents now runs on a control plane, so your iPhone and iPad see your servers too.")
                .appText(.supporting)
            Spacer()
            Button("Move Across…") { offering = true }.buttonStyle(.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Paper.wash)
        .sheet(isPresented: $offering) { MoveAcrossSheet().paperSheet() }
    }
}

struct MoveAcrossSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var move = MoveAcross()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to a control plane on this Mac").appText(.reading).fontWeight(.semibold)
            switch move.phase {
            case .offer:
                Text("This sets up a control plane on this Mac and keeps everything you have:")
                    .appText(.supporting).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    kept("All \(count(move.summary.agents, "agent")) and their conversations stay on this Mac, as this Mac’s host")
                    if !move.summary.devices.isEmpty {
                        kept("\(ListFormatter.localizedString(byJoining: move.summary.devices)) keep working, without pairing again")
                    }
                    if !move.summary.servers.isEmpty {
                        kept("\(ListFormatter.localizedString(byJoining: move.summary.servers)) are added as hosts, over your ssh as now")
                    }
                    kept("Work on this Mac carries on after a restart, without opening Agents")
                }
                Text("Your iPhone and iPad will be able to do what they can today, and now on your servers too. You can let one do everything in Settings ▸ Control plane ▸ Clients.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .moving(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).appText(.supporting)
                }
            case .done(let failed):
                Text("Moved. This window now works through the control plane on this Mac.").appText(.supporting).tinted(.vouched)
                if !failed.isEmpty {
                    Text("\(ListFormatter.localizedString(byJoining: failed)) couldn’t be added. Add them again in Settings ▸ Control plane ▸ Hosts.")
                        .appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let why):
                Text("Nothing has changed: \(why)").appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch move.phase {
                case .offer, .failed:
                    Button("Not Now") { dismiss() }
                    Button(move.phase == .offer ? "Move Across" : "Try Again") { go() }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                case .moving:
                    EmptyView()
                case .done:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isMoving)
    }

    private var isMoving: Bool { if case .moving = move.phase { true } else { false } }

    private func kept(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").tinted(.vouched)
            Text(text).appText(.reading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func go() {
        Task { await move.run(model: model) }
    }
}
