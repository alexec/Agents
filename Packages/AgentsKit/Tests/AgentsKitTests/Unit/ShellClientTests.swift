import Foundation
import Testing
@testable import AgentsKitCore

/// A screen's end of a shell: what it feeds its emulator, and what it sends (#401).
@MainActor
@Suite("A shell's screen", .timeLimit(.minutes(1)))
struct ShellClientTests {
    /// A daemon that answers `shell/attach` and `shell/restart` with what it is given,
    /// holds attach replies until it is let go, and writes down what was typed.
    final class Daemon: DaemonLink, @unchecked Sendable {
        private let lock = NSLock()
        private var _scrollback = Data()
        private var _dropped = 0
        private var _startedAt = Date(timeIntervalSince1970: 1000)
        private var _holdAttach = false
        private var _typed: [Data] = []
        private var _slowFirstInput = false
        private var _failInput = false

        var scrollback: Data { get { lock.withLock { _scrollback } } set { lock.withLock { _scrollback = newValue } } }
        var dropped: Int { get { lock.withLock { _dropped } } set { lock.withLock { _dropped = newValue } } }
        var startedAt: Date { get { lock.withLock { _startedAt } } set { lock.withLock { _startedAt = newValue } } }
        var holdAttach: Bool { get { lock.withLock { _holdAttach } } set { lock.withLock { _holdAttach = newValue } } }
        var slowFirstInput: Bool { get { lock.withLock { _slowFirstInput } } set { lock.withLock { _slowFirstInput = newValue } } }
        var failInput: Bool { get { lock.withLock { _failInput } } set { lock.withLock { _failInput = newValue } } }
        var typed: [Data] { lock.withLock { _typed } }

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            _ = Task { [weak self] in
                for try await line in far.lines() {
                    guard let self, let request = try? JSONValue.parse(Data(line.utf8)),
                          let id = request["id"]?.intValue else { continue }
                    let method = request["method"]?.stringValue ?? ""
                    Task { try? far.write(line: await self.answer(id, method, request["params"])) }
                }
            }
            return near
        }

        private func answer(_ id: Int, _ method: String, _ params: JSONValue?) async -> String {
            func result(_ value: some Encodable) -> String {
                let json = String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
                return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(json)}"#
            }
            switch method {
            case DaemonAPI.Method.shellAttach, DaemonAPI.Method.shellRestart:
                while holdAttach { try? await Task.sleep(for: .milliseconds(5)) }
                let restarting = method == DaemonAPI.Method.shellRestart
                return result(DaemonAPI.ShellAttachResponse(state: .live,
                                                            scrollback: restarting ? Data() : scrollback,
                                                            dropped: restarting ? 0 : dropped,
                                                            startedAt: startedAt))
            case DaemonAPI.Method.shellInput:
                let bytes = (try? params?.decode(DaemonAPI.ShellInputRequest.self))?.bytes ?? Data()
                let first = lock.withLock { () -> Bool in
                    _typed.append(bytes)
                    return _typed.count == 1
                }
                if first, slowFirstInput { try? await Task.sleep(for: .milliseconds(150)) }
                if failInput {
                    return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32011,"message":"That shell is not running."}}"#
                }
                return #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#
            default:
                return #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#
            }
        }
    }

    /// What the emulator was fed, in order.
    final class Screen {
        var fed = Data()
        var text: String { String(decoding: fed, as: UTF8.self) }
    }

    private func screen(_ daemon: Daemon) async throws -> (ShellClient, Screen) {
        let client = DaemonClient(link: daemon)
        try await client.connect(startIfNeeded: false)
        let shell = ShellClient(agentID: UUID(), client: client, describe: { "\($0)" })
        let screen = Screen()
        shell.onOutput = { screen.fed.append($0) }
        return (shell, screen)
    }

    @Test func outputDuringAnAttachIsShownOnceAfterTheReplay() async throws {
        let daemon = Daemon()
        daemon.scrollback = Data("abcd".utf8)
        daemon.holdAttach = true
        let (shell, screen) = try await screen(daemon)

        let attaching = Task { await shell.attach(rows: 24, cols: 80) }
        try await Task.sleep(for: .milliseconds(50))
        // Broadcast while the replay was being taken: the first half is in it.
        shell.received(Data("cd".utf8), at: 2)
        shell.received(Data("ef".utf8), at: 4)
        #expect(screen.fed.isEmpty)
        daemon.holdAttach = false
        await attaching.value

        #expect(screen.text == "abcdef")
        // Heard again later, as a broadcast can be: nothing new.
        shell.received(Data("ef".utf8), at: 4)
        #expect(screen.text == "abcdef")
    }

    @Test func comingBackGivesOnlyWhatWasMissed() async throws {
        let daemon = Daemon()
        daemon.scrollback = Data("abc".utf8)
        let (shell, screen) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)
        #expect(screen.text == "abc")

        shell.lostConnection()
        #expect(!shell.isAttached)
        // Missed while away.
        shell.received(Data("d".utf8), at: 3)
        daemon.scrollback = Data("abcdef".utf8)
        await shell.reattachIfLost()

        #expect(shell.isAttached)
        #expect(screen.text == "abcdef")
    }

    @Test func aShellThatIsNotTheOneOnScreenStartsTheScreenAgain() async throws {
        let daemon = Daemon()
        daemon.scrollback = Data("old".utf8)
        let (shell, screen) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)

        // The helper came back with a new shell in this place.
        shell.lostConnection()
        daemon.startedAt = Date(timeIntervalSince1970: 2000)
        daemon.scrollback = Data("new".utf8)
        await shell.reattachIfLost()

        #expect(screen.fed == Data("old".utf8) + ShellClient.reset + Data("new".utf8))
    }

    @Test func aNewShellStartsFromABlankScreen() async throws {
        let daemon = Daemon()
        daemon.scrollback = Data("vim".utf8)
        let (shell, screen) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)
        shell.received(.exited(status: 0))

        daemon.startedAt = Date(timeIntervalSince1970: 2000)
        await shell.restart(rows: 24, cols: 80)
        shell.received(Data("$ ".utf8), at: 0)

        #expect(screen.fed == Data("vim".utf8) + ShellClient.reset + Data("$ ".utf8))
    }

    @Test func aShellRestartedElsewhereIsShownFromItsStart() async throws {
        let daemon = Daemon()
        daemon.scrollback = Data("done".utf8)
        let (shell, screen) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)
        shell.received(.exited(status: 0))

        // The phone started a new one; its first words came before the news.
        shell.received(Data("$ ".utf8), at: 0)
        shell.received(.live)

        #expect(screen.fed == Data("done".utf8) + ShellClient.reset + Data("$ ".utf8))
        #expect(shell.state.isLive)
    }

    @Test func keystrokesGoInOrderAndTogether() async throws {
        let daemon = Daemon()
        daemon.slowFirstInput = true
        let (shell, _) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)

        shell.type(Data("l".utf8))
        // The first is on its way, and slow to be answered.
        await eventually("the first keystroke was sent") { !daemon.typed.isEmpty }
        for key in ["s", " ", "-", "l", "\r"] { shell.type(Data(key.utf8)) }
        await eventually("everything typed was sent") { daemon.typed.reduce(0) { $0 + $1.count } == 6 }

        #expect(daemon.typed.reduce(Data(), +) == Data("ls -l\r".utf8))
        // One request in flight at a time: what was typed meanwhile went as one.
        #expect(daemon.typed.count == 2)
    }

    @Test func typingThatDoesNotArriveIsSaid() async throws {
        let daemon = Daemon()
        daemon.failInput = true
        let (shell, _) = try await screen(daemon)
        await shell.attach(rows: 24, cols: 80)

        shell.type(Data("x".utf8))
        await eventually("the failure is said") { await MainActor.run { shell.sendProblem != nil } }

        daemon.failInput = false
        shell.type(Data("y".utf8))
        await eventually("a keystroke that arrives clears it") { await MainActor.run { shell.sendProblem == nil } }
    }
}
