import AgentsKitCore
import AppKit

/// Move to Another Machine… and Run It Here Again… asked by a client of the person (#4255):
/// the move runs `agents-control handover` with this Mac's control key and changes this Mac's
/// launch agents, which only the window on this Mac does. So a page asks with
/// `control/planeMove`, the control plane tells the person's windows `control/planeMoveWanted`,
/// and the window whose Mac it concerns does the step as its own sheet does (`MachineMove`,
/// `MachineReturn`). How it stands, the Overview's rows and the sheet the page opened, goes
/// back as `control/planeMoveReport` in the sheet's words, while the page may still look. The
/// key never leaves this Mac: Save Key… and Use Key… open their panels here.
@MainActor
enum PlaneMoveWanted {
    private static var move: MachineMove?
    private static var back: MachineReturn?
    private static var control: DaemonClient?
    private static var askedAt = Date.distantPast
    private static var watching: Task<Void, Never>?
    private static var said: PlaneMove.Report?
    private static var problem: String?
    /// This Mac's name, once: `Host.current()` can be slow.
    private static let macName = Host.current().localizedName ?? "This Mac"

    static func heard(_ params: JSONValue?, on control: DaemonClient) async {
        guard let ask = try? params?.decode(PlaneMove.Ask.self), let host = HostScenes.model,
              move != nil || back != nil || concerns(host) else { return }
        self.control = control
        askedAt = Date()
        watch()
        await act(ask, host: host)
        await report(host, always: true)
    }

    /// The control plane runs here, or this Mac moved it away.
    private static func concerns(_ host: HostModel) -> Bool {
        host.settings.role == .runHere && host.settings.movedTo == nil
            || host.settings.role == .joinElsewhere && host.settings.movedTo != nil
    }

    private static func act(_ ask: PlaneMove.Ask, host: HostModel) async {
        problem = nil
        switch ask.action {
        case .status:
            break
        case .move:
            guard move == nil, back == nil, host.settings.role == .runHere, host.controlRunning, host.busy == nil else { return }
            move = MachineMove(model: host)
        case .return:
            guard move == nil, back == nil, host.settings.role == .joinElsewhere, host.busy == nil else { return }
            let opened = MachineReturn(model: host)
            back = opened
            await opened.check()
        case .saveKey:
            NSApp.activate()
            move?.saveKey()
        case .useKey:
            NSApp.activate()
            await back?.useKey()
        case .continue:
            if move?.step == .key { move?.step = .check }
        case .back:
            if move?.step == .check { move?.step = .key }
        case .check:
            if let move {
                // The page names no scheme of its own (it reaches only its own origin): https.
                if let address = ask.address?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    move.address = address.contains("://") ? address : "https://" + address
                }
                await move.check()
            } else {
                await back?.check()
            }
        case .announce:
            if let move { await move.tellEveryone() } else { await back?.tellEveryone() }
        case .withdraw:
            if let move { await move.withdraw() } else { await back?.withdraw() }
        case .moveNow:
            if let move { await move.moveNow() } else { await back?.moveNow() }
            if move?.finished == true { move = nil }
            if back?.finished == true { back = nil }
        case .cancel:
            if let move { await move.cancel() } else { await back?.cancel() }
            move = nil
            back = nil
        case .close:
            move = nil
            back = nil
        case .stopForwarding:
            await host.stopForwarding()
        case .stopReturnForwarding:
            await host.stopReturnForwarding()
            problem = host.problem
        case .dismiss:
            host.dismissReturn()
        }
    }

    /// Says how it stands each second it changes, while a sheet is open or for ten minutes
    /// after the page last asked.
    private static func watch() {
        guard watching == nil else { return }
        watching = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let host = HostScenes.model else { break }
                if move?.finished == true { move = nil }
                if back?.finished == true { back = nil }
                if move == nil, back == nil, Date().timeIntervalSince(askedAt) > 600 { break }
                await report(host, always: false)
            }
            watching = nil
        }
    }

    private static func report(_ host: HostModel, always: Bool) async {
        let now = PlaneMove.Report(mac: macName, rows: rows(host), flow: flow(host), problem: problem)
        guard always || now != said, let control else { return }
        said = now
        _ = try? await control.call(DaemonAPI.Method.controlPlaneMoveReport, now, returning: DaemonAPI.Empty.self)
    }

    // MARK: The Overview's rows, as HostControlPlaneCards draws them

    static func rows(_ host: HostModel) -> [PlaneMove.Row] {
        typealias Cards = HostControlPlaneCards
        var rows: [PlaneMove.Row] = []
        if host.settings.role == .runHere {
            rows.append(.init(kind: .move, title: "Move to Another Machine", detail: Cards.moveDetail, button: "Move…",
                              action: .move, disabled: !host.controlRunning || host.busy != nil))
            if let place = host.settings.returnedFrom {
                let done = host.returnForwardingDone
                rows.append(.init(kind: .returned, title: Cards.returnTitle(place, host: host),
                                  detail: done ? "" : Cards.returnLine(host), attention: !done,
                                  button: done ? "Dismiss" : "Stop Forwarding…", action: done ? .dismiss : .stopReturnForwarding,
                                  confirm: done ? nil : Cards.stopMessage(host.returnForwarding)))
            }
        } else if host.settings.role == .joinElsewhere, let place = host.settings.movedTo {
            rows.append(.init(kind: .moved, title: "This Mac moved its control plane", detail: Cards.movedLine(place, host: host),
                              attention: !host.daemonRunning, button: "Run It Here Again…", action: .return,
                              disabled: host.busy != nil))
            if let until = host.settings.forwardingUntil {
                rows.append(.init(kind: .forwarding, title: "Forwarding from \(host.controlURL)",
                                  detail: Cards.forwardingLine(until, host.forwarding), attention: true,
                                  button: "Stop Forwarding…", action: .stopForwarding, confirm: Cards.stopMessage(host.forwarding)))
            }
        }
        return rows
    }

    // MARK: The sheet the page opened, as MachineMoveSheet and MachineReturnSheet draw it

    static func flow(_ host: HostModel) -> PlaneMove.Flow? {
        if let move { return flow(move) }
        if let back { return flow(back, host: host) }
        return nil
    }

    static func flow(_ move: MachineMove) -> PlaneMove.Flow {
        let title = "Move the control plane to another machine"
        switch move.step {
        case .key:
            return .init(kind: .move, step: .key, title: title,
                         lead: "Your windows, phones and servers stay paired, and this Mac stays a machine. Agents keep working while it moves.",
                         problem: move.problem)
        case .check:
            return .init(kind: .move, step: .check, title: title, address: move.address, lines: [
                line(move.answers, "It answers"),
                line(move.trusted, "Its certificate is publicly trusted", note: "So no pin is needed, and it renews itself."),
                line(move.holdsKey, "It holds this control plane's key"),
                line(move.empty, "It's empty, and waiting for this one"),
            ], checked: move.checked, busy: move.checking, problem: move.problem)
        case .told:
            return .init(kind: .move, step: .told, title: title,
                         lead: "Everything that's paired now knows \(move.address) as well as this Mac.", address: move.address,
                         members: members(move.status, learnsFrom: "this Mac"), knowing: knowing(move.status), problem: move.problem)
        case .moving:
            let name = URL(string: move.address)?.host ?? move.address
            return .init(kind: .move, step: .moving, title: "Moving to \(name)…", address: move.address, lines: [
                line(move.stages[0], "Holding records still", note: "Pairing and changes wait. Agents keep working."),
                line(move.stages[1], move.copied ?? "Copying records"),
                line(move.stages[2], "\(URL(string: move.address)?.host ?? "It") takes over"),
                line(move.stages[3], "The machine on this Mac goes there"),
                line(move.stages[4], "This Mac sends anyone still coming here on to it"),
            ], taken: move.taken, failed: move.stages.contains(.failed), problem: move.problem)
        }
    }

    static func flow(_ back: MachineReturn, host: HostModel) -> PlaneMove.Flow {
        let title = "Bring the control plane back to this Mac"
        switch back.step {
        case .check:
            return .init(kind: .return, step: .check, title: title,
                         lead: "Your windows, phones and servers stay paired. Agents keep working while it moves.",
                         address: back.place, lines: [
                             line(back.reachable, "\(back.placeName) answers, and holds this control plane's key"),
                             line(back.ready, "This Mac's copy is ready, empty, waiting for it",
                                  note: back.aside.map { "The store from before the move is kept in Agents Control as \($0)." }),
                             .init(label: "Away from home, iPhone and iPad can't reach this Mac directly", state: .warning,
                                   note: "\(back.placeName) had a public address; this Mac doesn't. On your network they connect as before. Away, they can't reach it."),
                         ], otherKey: back.otherKey, checked: back.checked, busy: back.checking, problem: back.problem)
        case .told:
            let here = URL(string: host.controlURL)?.host ?? "this Mac"
            return .init(kind: .return, step: .told, title: title,
                         lead: "Everything that's paired now knows \(here) as well as \(back.placeName).", address: back.place,
                         members: members(back.status, learnsFrom: back.placeName), knowing: knowing(back.status), problem: back.problem)
        case .moving:
            return .init(kind: .return, step: .moving, title: "Moving back to this Mac…", address: back.place, lines: [
                line(back.stages[0], "Holding records still at \(back.placeName)", note: "Pairing and changes wait. Agents keep working."),
                line(back.stages[1], back.copied ?? "Copying records to this Mac"),
                line(back.stages[2], "This Mac takes over"),
                line(back.stages[3], "Machines come back here"),
                line(back.stages[4], "\(back.placeName) sends anyone still going there on to this Mac"),
            ], taken: back.taken, failed: back.stages.contains(.failed), problem: back.problem)
        }
    }

    static func line(_ tick: MachineMove.Tick, _ label: String, note: String? = nil) -> PlaneMove.Line {
        switch tick {
        case .waiting: .init(label: label, state: .waiting)
        case .yes: .init(label: label, state: .yes, note: note)
        case .no(let why): .init(label: label, state: .no, note: why)
        }
    }

    static func line(_ stage: MachineMove.Stage, _ label: String, note: String? = nil) -> PlaneMove.Line {
        let state: PlaneMove.Line.State = switch stage {
        case .todo: .todo
        case .doing: .doing
        case .done: .done
        case .failed: .failed
        }
        return .init(label: label, state: state, note: note)
    }

    static func members(_ status: HandoverStatus?, learnsFrom: String) -> [PlaneMove.Member]? {
        status?.members.map { member in
            let name = member.id == MachineRef.mac.rawValue ? "This Mac" : member.name
            let kind = MachineMoveSheet.kind(member)
            if member.knows(status?.epoch) { return .init(name: name, kind: kind, state: .knows) }
            if member.online == true {
                return .init(name: name, kind: kind, state: .cantFollow, note: "Update it first, or add it again afterwards")
            }
            return .init(name: name, kind: kind, state: .notYet, note: "Learns it from \(learnsFrom) when it next connects")
        }
    }

    static func knowing(_ status: HandoverStatus?) -> String? {
        guard let status else { return nil }
        let knowing = status.members.count - status.stillToHear.count
        return "\(knowing) of \(status.members.count) know. You can move now, or wait for the rest."
    }
}
