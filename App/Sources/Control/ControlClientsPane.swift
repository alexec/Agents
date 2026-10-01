import AgentsKitCore
import SwiftUI

// MARK: - F · Clients

struct ControlClientsPage: View {
    let control: ControlSettingsModel
    @State private var forgettingClient: ClientRecord?
    @State private var pairingDevice = false
    @State private var pairingMac = false

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
            }
            Text("Forgetting cuts a client off at once, directly and through the relay. To use it again, pair it again.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $pairingDevice) { PairDeviceSheet(control: control) }
        .sheet(isPresented: $pairingMac) { CodeSheet(control: control, purpose: .mac).paperSheet() }
        .confirmationDialog(forgettingClient.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgettingClient != nil }, set: { if !$0 { forgettingClient = nil } }),
                            titleVisibility: .visible, presenting: forgettingClient) { client in
            Button("Forget", role: .destructive) { Task { await control.forget(client.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is cut off at once, at home and away, until it is paired again.")
        }
    }

    private func clientRow(_ client: ClientRecord) -> some View {
        let isYou = client.id == control.status?.you
        let link = control.connections[client.id]
        let away = link?.relayed == true
        let line = clientLine(client, isYou: isYou)
        return ControlRow(dot: .none, title: isYou ? "This window" : client.name, chip: isYou ? "you" : away ? "away" : nil,
                          chipTone: away ? .attention : .source, detail: line.plain, detailText: line.drawn) {
            HStack(spacing: 8) {
                grantPicker(client.grant) { grant in
                    Task { await control.setGrant(grant, of: client.id) }
                }
                // A refused change leaves the record as it was, which a Binding alone would
                // not redraw: the segment clicked would stay lit.
                .id("\(client.grant.rawValue)-\(control.revision)")
                if !isYou {
                    Button("Forget…") { forgettingClient = client }.buttonStyle(.paper)
                }
            }
        }
    }

    private func grantPicker(_ grant: Grant, change: @escaping (Grant) -> Void) -> some View {
        Picker("Grant", selection: Binding(get: { grant }, set: { if $0 != grant { change($0) } })) {
            Text("Operator").tag(Grant.operator)
            Text("Device").tag(Grant.device)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Frame N: what it is, then how it reaches the control plane now: directly, through
    /// a Mac's iCloud relay (named, and emphasised), or when it was last seen.
    private func clientLine(_ client: ClientRecord, isYou: Bool) -> (plain: String, drawn: Text) {
        let kind = switch client.kind {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
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
