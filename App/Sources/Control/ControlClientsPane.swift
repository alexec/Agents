import AgentsKitCore
import SwiftUI

// MARK: - F · Clients

struct ControlClientsPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var forgettingClient: ClientRecord?
    /// Forget This Mac (#344): the window's own row, asked the same way as any other's.
    @State private var forgettingThisWindow = false
    @State private var pairingDevice = false
    @State private var pairingMac = false
    @State private var pairingBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard {
                ForEach(Array(control.clients.enumerated()), id: \.element.id) { index, client in
                    if index > 0 { Divider() }
                    clientRow(client)
                }
            }
            HStack(spacing: 8) {
                Button("Pair a Device…") { pairingDevice = true }.buttonStyle(.paper)
                Button("Pair a Mac…") { pairingMac = true }.buttonStyle(.paper)
                Button("Pair a Browser…") { pairingBrowser = true }.buttonStyle(.paper)
            }
            Text("Forgetting cuts a client off at once, directly and through the relay. To use it again, pair it again.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $pairingDevice) { PairDeviceSheet(control: control) }
        .sheet(isPresented: $pairingMac) { CodeSheet(control: control, purpose: .mac).paperSheet() }
        .sheet(isPresented: $pairingBrowser) { CodeSheet(control: control, purpose: .browser).paperSheet() }
        .confirmationDialog(forgettingClient.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgettingClient != nil }, set: { if !$0 { forgettingClient = nil } }),
                            titleVisibility: .visible, presenting: forgettingClient) { client in
            Button("Forget", role: .destructive) { Task { await control.forget(client.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is cut off at once, at home and away, until it is paired again.")
        }
        .confirmationDialog("Forget this window?", isPresented: $forgettingThisWindow, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task { if await control.forgetThisWindow() { model.leaveControlPlane() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This window is cut off at once, at home and away, until it is paired again.")
        }
    }

    private func clientRow(_ client: ClientRecord) -> some View {
        let isYou = client.id == control.status?.you
        let link = control.connections[client.id]
        let away = link?.relayed == true
        let line = clientLine(client, isYou: isYou)
        return ControlRow(dot: .none, title: isYou ? "This window" : client.name, chip: isYou ? "you" : away ? "away" : nil,
                          chipTone: away ? .attention : .source, detail: line.plain, detailText: line.drawn) {
            if isYou {
                Button("Forget This Mac…") { forgettingThisWindow = true }.buttonStyle(.paper)
            } else {
                Button("Forget…") { forgettingClient = client }.buttonStyle(.paper)
            }
        }
    }

    /// Frame N: what it is, then how it reaches the control plane now: directly, through
    /// a Mac's iCloud relay (named, and emphasised), or when it was last seen.
    private func clientLine(_ client: ClientRecord, isYou: Bool) -> (plain: String, drawn: Text) {
        let kind = switch client.kind {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .browser: "Browser"
        case .unknown: "Device"
        }
        let link = control.connections[client.id]
        if let link, link.relayed {
            let through = link.through ?? "a Mac"
            return ("\(kind) · connected through \(through) (iCloud relay)",
                    Text("\(kind) · connected through \(Text(through).fontWeight(.semibold)) (iCloud relay)"))
        }
        let how: String = if link != nil || isYou {
            "connected directly"
        } else if let seen = client.lastSeen {
            "seen \(seen.formatted(.relative(presentation: .named)))"
        } else {
            "paired \(client.paired.formatted(.relative(presentation: .named)))"
        }
        return ("\(kind) · \(how)", Text("\(kind) · \(how)"))
    }
}
