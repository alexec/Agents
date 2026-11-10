import AgentsKitCore
import SwiftUI

/// Later on a request to the person (#4234, epic #4232): In 1 Hour, This Evening, Tomorrow
/// Morning, At My Mac and Pick a Time…, in a Needs you row's menu and on the request's card.
/// A deferred request stays open, its sessions still wait, and it moves to Needs you's
/// folded Later group, out of the count and the Dock badge, until it comes back. In Later,
/// Bring Back Now does that at once, and Later again moves its time.
struct RequestLaterMenu: View {
    @Environment(AppModel.self) private var model
    let request: NeedRequest
    /// Pick a Time…: the caller opens `RequestTimePicker`.
    let pick: () -> Void
    /// The choices in a Later submenu, as a row's menu has them; flat, as the card's own
    /// Later menu has them.
    var nested = true

    var body: some View {
        if request.isDeferred {
            Button("Bring Back Now") { Task { await model.undeferRequest(request) } }
        }
        if nested {
            Menu("Later") { choices }
        } else {
            if request.isDeferred { Divider() }
            choices
        }
    }

    @ViewBuilder
    private var choices: some View {
        ForEach(NeedRequest.Later.allCases, id: \.self) { later in
            Button(later.word) { Task { await model.deferRequest(request, later.params(id: request.id)) } }
        }
        Divider()
        Button("Pick a Time…", action: pick)
    }
}

/// Pick a Time… (#4234): a date and a time after now, then Later.
struct RequestTimePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NeedRequest
    @State private var until = Date.now.addingTimeInterval(3 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring it back at").appText(.reading).fontWeight(.semibold)
            Text(request.title(asker: nil)).appText(.supporting).foregroundStyle(.secondary).lineLimit(2)
            // The day on a calendar, the time typed: a clock face sets no exact minute.
            DatePicker("Day", selection: $until, in: Date.now..., displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
            DatePicker("Time", selection: $until, in: Date.now..., displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .fixedSize()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Later") {
                    let params = DaemonAPI.RequestsDefer(id: request.id, until: until)
                    Task {
                        if await model.deferRequest(request, params) { dismiss() }
                    }
                }
                .buttonStyle(.paperProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(until <= .now)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// On a request's card (#4234): Later, at its top end; in Later, when it comes back and
/// Bring Back Now.
struct RequestCardLater: View {
    @Environment(AppModel.self) private var model
    let request: NeedRequest
    @State private var picking = false

    var body: some View {
        HStack(spacing: 6) {
            if let deferred = request.deferred {
                Text("In Later · \(deferred.back())")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            Menu {
                RequestLaterMenu(request: request, pick: { picking = true }, nested: false)
            } label: {
                Image(systemName: "clock")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Later: take it out of Needs you until a time, or until you are at your Mac")
            .accessibilityLabel("Later")
        }
        .sheet(isPresented: $picking) { RequestTimePicker(request: request) }
    }
}
