import AgentsKitCore
import SwiftUI

/// Later on a request to the person (#4234, epic #4232): In 1 Hour, 4 Hours, 8 Hours, 1 Day
/// and At My Mac in a Needs you row's menu; 1h, 4h, 8h and 1d on the request's card. A
/// deferred request stays open, its sessions still wait, and it moves to Needs you's folded
/// Later group, out of the count and the Dock badge, until it comes back. In Later, Bring
/// Back Now does that at once, and Later again moves its time.
struct RequestLaterMenu: View {
    @Environment(AppModel.self) private var model
    let request: NeedRequest

    var body: some View {
        if request.isDeferred {
            Button("Bring Back Now") { Task { await model.undeferRequest(request) } }
        }
        Menu("Later") {
            ForEach(NeedRequest.Later.allCases, id: \.self) { later in
                if later == .atMac { Divider() }
                Button(later.word) { Task { await model.deferRequest(request, later.params(id: request.id)) } }
            }
        }
    }
}

/// On a request's card (#4234), at its top end: Later and one small button for each time,
/// 1h, 4h, 8h, 1d; in Later, when it comes back and Bring Back Now.
struct RequestCardLater: View {
    @Environment(AppModel.self) private var model
    let request: NeedRequest

    var body: some View {
        HStack(spacing: 6) {
            if let deferred = request.deferred {
                Text("In Later · \(deferred.back())")
                    .foregroundStyle(.secondary)
                Button("Bring Back Now") { Task { await model.undeferRequest(request) } }
            } else {
                Text("Later").foregroundStyle(.secondary)
                ForEach(NeedRequest.Later.timed, id: \.self) { later in
                    Button(later.short) { Task { await model.deferRequest(request, later.params(id: request.id)) } }
                        .help("Out of Needs you, back \(later.word.lowercased())")
                        .accessibilityLabel("Later, \(later.word)")
                }
            }
        }
        .buttonStyle(.paper)
        .controlSize(.small)
        .appText(.fine)
    }
}
