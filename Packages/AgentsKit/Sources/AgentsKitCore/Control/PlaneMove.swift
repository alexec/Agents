import Foundation

/// Move to Another Machine… and Run It Here Again… asked by any client of the person (#4255):
/// `control/planeMove` and `control/planeMoveWanted`, then `control/planeMoveReport` and
/// `control/planeMoveReported`. The window on the Mac that moves the control plane does each
/// step with this Mac's control key, which never leaves the Mac, and says how it stands in
/// its own words, so the page draws what the window's sheet would.
public enum PlaneMove {
    public enum Action: String, Codable, Hashable, Sendable, CaseIterable {
        case status, move
        case `return`
        case saveKey, useKey
        case `continue`
        case back, check, announce, withdraw, moveNow, cancel, close
        case stopForwarding, stopReturnForwarding, dismiss
    }

    /// `PlaneMoveAsk`: one step, and with `check` on a move, where the other machine is.
    public struct Ask: Codable, Hashable, Sendable {
        public var action: Action
        public var address: String?

        public init(action: Action, address: String? = nil) {
            self.action = action
            self.address = address
        }
    }

    /// `PlaneMoveLine`: one check or stage.
    public struct Line: Codable, Hashable, Sendable {
        public enum State: String, Codable, Hashable, Sendable { case waiting, yes, no, todo, doing, done, failed, warning }
        public var label: String
        public var state: State
        public var note: String?

        public init(label: String, state: State, note: String? = nil) {
            self.label = label
            self.state = state
            self.note = note
        }
    }

    /// `PlaneMoveMember`: whether one window, phone or machine knows where it goes.
    public struct Member: Codable, Hashable, Sendable {
        public enum State: String, Codable, Hashable, Sendable { case knows, cantFollow, notYet }
        public var name: String
        public var kind: String
        public var state: State
        public var note: String?

        public init(name: String, kind: String, state: State, note: String? = nil) {
            self.name = name
            self.kind = kind
            self.state = state
            self.note = note
        }
    }

    /// `PlaneMoveFlow`: the sheet a client opened, as the window would draw it.
    public struct Flow: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable { case move, `return` }
        public enum Step: String, Codable, Hashable, Sendable { case key, check, told, moving }
        public var kind: Kind
        public var step: Step
        public var title: String
        public var lead: String?
        public var address: String?
        public var lines: [Line]?
        public var members: [Member]?
        public var knowing: String?
        public var otherKey: Bool?
        public var checked: Bool?
        public var busy: Bool?
        public var taken: Bool?
        public var failed: Bool?
        public var problem: String?

        public init(kind: Kind, step: Step, title: String, lead: String? = nil, address: String? = nil,
                    lines: [Line]? = nil, members: [Member]? = nil, knowing: String? = nil, otherKey: Bool? = nil,
                    checked: Bool? = nil, busy: Bool? = nil, taken: Bool? = nil, failed: Bool? = nil, problem: String? = nil) {
            self.kind = kind
            self.step = step
            self.title = title
            self.lead = lead
            self.address = address
            self.lines = lines
            self.members = members
            self.knowing = knowing
            self.otherKey = otherKey
            self.checked = checked
            self.busy = busy
            self.taken = taken
            self.failed = failed
            self.problem = problem
        }
    }

    /// `PlaneMoveRow`: a row of the control plane's move card in Settings ▸ Control plane ▸ Overview.
    public struct Row: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable { case move, moved, forwarding, returned }
        public var kind: Kind
        public var title: String
        public var detail: String
        public var attention: Bool?
        public var button: String?
        public var action: Action?
        public var disabled: Bool?
        public var confirm: String?

        public init(kind: Kind, title: String, detail: String, attention: Bool? = nil, button: String? = nil,
                    action: Action? = nil, disabled: Bool? = nil, confirm: String? = nil) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.attention = attention
            self.button = button
            self.action = action
            self.disabled = disabled
            self.confirm = confirm
        }
    }

    /// `PlaneMoveReport`: how a move stands on the Mac that does it.
    public struct Report: Codable, Hashable, Sendable {
        public var mac: String
        public var rows: [Row]
        public var flow: Flow?
        public var problem: String?

        public init(mac: String, rows: [Row], flow: Flow? = nil, problem: String? = nil) {
            self.mac = mac
            self.rows = rows
            self.flow = flow
            self.problem = problem
        }
    }
}
