import Foundation
import Observation

/// A window's or a phone's end of one of an agent's shells.
///
/// One per shell per client. The phone only ever has shell 0; the Mac has one for each
/// terminal tab (055). It talks to the daemon, which owns the shell; this holds
/// nothing but a way to reach it and the state it was last told about. Closing the
/// window, or putting the phone away, takes this with it and leaves the shell running
/// (FR-026).
///
/// In Core since 034, so the phone attaches to the same shell the Mac's pane shows
/// rather than having one of its own: one shell per agent, owned by the Mac, and every
/// screen looking at it is a view of it.
@MainActor
@Observable
public final class ShellClient {
    public let agentID: UUID
    /// Which of the agent's shells. Zero is the one every agent has.
    public let shell: Int
    public private(set) var state: ShellState = .live
    public private(set) var isAttached = false
    public private(set) var problem: String?
    /// Bytes the daemon says were dropped off the front of the buffer. Non-zero means
    /// the replay is the end of the session rather than the whole of it.
    public private(set) var dropped = 0
    /// The folder this shell was started in, once attached. An agent that has moved since
    /// (053) works somewhere else, and the pane says so.
    public private(set) var folder: URL?

    /// Typing that did not reach the shell, said under the screen rather than lost in
    /// silence (#401). Cleared by the next keystroke that does.
    public private(set) var sendProblem: String?

    /// Where incoming bytes go: the emulator, set by the pane once its view exists. A
    /// new emulator is a blank screen, so it is caught up from the daemon's replay.
    @ObservationIgnored public var onOutput: ((Data) -> Void)? {
        didSet {
            seen = nil
            if onOutput != nil, isAttached { Task { await self.attach(rows: self.rows, cols: self.cols) } }
        }
    }

    private let client: DaemonClient
    private let describe: @MainActor (any Error) -> String
    /// This screen's size, as last laid out. Sent with every keystroke, so the shell
    /// takes the size of whichever screen typed last (034, US4 scenario 5).
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var cols = 0

    /// How far into everything the shell has printed this screen has got: the offset
    /// just past the last byte fed to it. Nil while the screen has nothing of this
    /// shell on it. Output carries its offset, so a chunk the replay already held is
    /// dropped rather than printed twice (#401).
    @ObservationIgnored private var seen: Int?
    /// When the shell the screen shows was started: a different one, after the helper
    /// came back, starts its offsets again from nothing.
    @ObservationIgnored private var startedAt: Date?
    /// Output that arrived while an attach was on its way. It may be in the replay or
    /// after it, and only the replay says which, so it waits for it.
    @ObservationIgnored private var held: [(bytes: Data, offset: Int?)]?
    /// The connection went while attached. The next connection attaches again.
    @ObservationIgnored private var lost = false
    /// Typed and not yet sent, and the one task sending it. One request at a time, in
    /// order, with whatever was typed meanwhile sent together: a task per keystroke
    /// let them overtake each other (#401).
    @ObservationIgnored private var outbox = Data()
    @ObservationIgnored private var sender: Task<Void, Never>?

    /// What an emulator is told to start again from blank: RIS, a full reset. It also
    /// turns off whatever modes a program left on (mouse, bracketed paste, the
    /// alternate screen).
    static let reset = Data("\u{1B}c".utf8)

    public init(agentID: UUID, shell: Int = 0, client: DaemonClient,
                describe: @escaping @MainActor (any Error) -> String) {
        self.agentID = agentID
        self.shell = shell
        self.client = client
        self.describe = describe
    }

    /// Attach, or catch up a screen that has nothing on it yet. Says its size but does
    /// not take the shell to it.
    public func attach(rows: Int, cols: Int) async {
        guard !isAttached || seen == nil, held == nil else { return }
        remember(rows: rows, cols: cols)
        held = []
        do {
            let response = try await client.call(
                DaemonAPI.Method.shellAttach,
                DaemonAPI.ShellAttachRequest(agentID: agentID, shell: shell,
                                             rows: rows > 0 ? rows : 24, cols: cols > 0 ? cols : 80),
                returning: DaemonAPI.ShellAttachResponse.self)
            state = response.state
            dropped = response.dropped
            folder = response.folder
            isAttached = true
            lost = false
            problem = nil
            catchUp(response.scrollback, from: response.dropped, startedAt: response.startedAt)
            showHeld()
        } catch {
            held = nil
            problem = describe(error)
            isAttached = false
        }
    }

    /// Replay what the shell printed that this screen has not shown. Feeding the bytes
    /// gives the same screen as having watched all along, which is the property the
    /// whole design rests on. A screen already showing part of it gets only the rest;
    /// one that missed bytes no longer held, or shows another shell's, starts again.
    private func catchUp(_ scrollback: Data, from start: Int, startedAt: Date) {
        let end = start + scrollback.count
        defer { self.startedAt = startedAt }
        guard let onOutput else { seen = nil; return }
        if let seen, self.startedAt == startedAt, seen >= start, seen <= end {
            if seen < end { onOutput(scrollback.suffix(end - seen)) }
        } else {
            if seen != nil { onOutput(Self.reset) }
            if !scrollback.isEmpty { onOutput(scrollback) }
        }
        seen = end
    }

    private func showHeld() {
        let waiting = held ?? []
        held = nil
        for chunk in waiting { show(chunk.bytes, at: chunk.offset) }
    }

    /// Detaching never stops anything. A build carries on (FR-026).
    public func detach() async {
        guard isAttached else { return }
        isAttached = false
        lost = false
        _ = try? await client.call(DaemonAPI.Method.shellDetach, DaemonAPI.ShellRequest(agentID: agentID, shell: shell))
    }

    /// End this shell for good: its tab was closed (055).
    public func close() async {
        isAttached = false
        lost = false
        onOutput = nil
        _ = try? await client.call(DaemonAPI.Method.shellClose, DaemonAPI.ShellRequest(agentID: agentID, shell: shell))
    }

    /// The connection went: whatever the daemon knew of this screen went with it. The
    /// next attach replays what was missed, and only that.
    public func lostConnection() {
        guard isAttached || held != nil else { return }
        isAttached = false
        held = nil
        lost = true
    }

    /// A new connection: attach again if the last one was lost while attached (#401).
    public func reattachIfLost() async {
        guard lost, !isAttached else { return }
        await attach(rows: rows, cols: cols)
    }

    /// What the person typed, queued and sent in order. Returns at once.
    public func type(_ data: Data) {
        guard state.isLive, !data.isEmpty else { return }
        outbox.append(data)
        guard sender == nil else { return }
        sender = Task { await self.drainOutbox() }
    }

    private func drainOutbox() async {
        while !outbox.isEmpty {
            let bytes = outbox
            outbox = Data()
            do {
                _ = try await client.call(DaemonAPI.Method.shellInput,
                                      DaemonAPI.ShellInputRequest(agentID: agentID, shell: shell, bytes: bytes,
                                                                  rows: rows > 0 ? rows : nil,
                                                                  cols: cols > 0 ? cols : nil))
                sendProblem = nil
            } catch {
                // Typing queued behind a failure is not sent later out of context.
                outbox = Data()
                sendProblem = "What you typed did not reach the shell: \(describe(error))"
            }
        }
        sender = nil
    }

    public func resize(rows: Int, cols: Int) async {
        guard state.isLive, rows > 0, cols > 0 else { return }
        remember(rows: rows, cols: cols)
        _ = try? await client.call(DaemonAPI.Method.shellResize,
                               DaemonAPI.ShellResizeRequest(agentID: agentID, shell: shell, rows: rows, cols: cols))
    }

    /// A new shell, once this one is over (FR-024). The screen starts again from blank:
    /// the new prompt is not drawn inside a dead program's screen, with its modes still
    /// on (#401).
    public func restart(rows: Int, cols: Int) async {
        remember(rows: rows, cols: cols)
        held = []
        do {
            let response = try await client.call(
                DaemonAPI.Method.shellRestart,
                DaemonAPI.ShellAttachRequest(agentID: agentID, shell: shell, rows: rows, cols: cols),
                returning: DaemonAPI.ShellAttachResponse.self)
            if startedAt != response.startedAt { beginAgain() }
            startedAt = response.startedAt
            state = response.state
            dropped = 0
            folder = response.folder
            isAttached = true
            lost = false
            problem = nil
            sendProblem = nil
            showHeld()
        } catch {
            held = nil
            problem = describe(error)
        }
    }

    // MARK: Told by the daemon

    public func received(_ data: Data, at offset: Int? = nil) {
        if held != nil {
            held?.append((data, offset))
            return
        }
        guard isAttached else { return }
        show(data, at: offset)
    }

    public func received(_ state: ShellState) {
        // A shell that was over and is live again is a new one, started from another
        // screen: its output starts again from nothing.
        if !self.state.isLive, state.isLive { beginAgain() }
        self.state = state
    }

    /// Feed what this screen has not shown yet, and nothing it has.
    private func show(_ data: Data, at offset: Int?) {
        guard let onOutput else { return }
        guard let offset else {
            // A host before #401: no offsets, so shown as it comes.
            onOutput(data)
            return
        }
        // The start of a new shell's output, after this one ended: a new shell begun on
        // another screen, whose news may come after its first words.
        if !state.isLive, offset == 0, let seen, seen > 0 { beginAgain() }
        guard let seen else { return }
        let end = offset + data.count
        guard end > seen else { return }
        onOutput(offset >= seen ? data : data.suffix(end - seen))
        self.seen = end
    }

    /// A new shell in this place: a blank screen, and its output from the start.
    private func beginAgain() {
        onOutput?(Self.reset)
        seen = onOutput == nil ? nil : 0
        dropped = 0
        state = .live
    }

    private func remember(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        self.rows = rows
        self.cols = cols
    }
}
