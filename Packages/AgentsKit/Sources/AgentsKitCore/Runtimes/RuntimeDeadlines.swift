import Foundation

/// How long a runtime is given for each thing it is asked to do before the app lets it go
/// (#166). A runtime alive but silent — an `npx` fetch stalled, a sign-in prompt on a
/// terminal nobody can see, a deadlocked node — otherwise holds its agent in `starting`
/// or `running` for ever: a running slot taken, the daemon never idle, and for a workflow's
/// agent nobody watching.
///
/// Kept on `RuntimeLaunch`, so a runtime that is known to be slow at one of these can be
/// given longer there without anything else branching on its id.
public struct RuntimeDeadlines: Hashable, Sendable {
    /// From the process starting to the answer to `initialize`. A cold `npx` start fetches
    /// the adapter first, which is most of a minute on a slow line.
    public var handshake: Duration
    /// `session/new`: a runtime reading its folder, its MCP servers and its plugins.
    public var start: Duration
    /// `session/resume` or `session/load`, and the sign-in a load may need first. Longer,
    /// because a load replays the whole conversation.
    public var load: Duration
    /// A turn under way that says nothing at all, with nothing pending: no tool call open,
    /// no question waiting on the person, nothing the app is running for it. A tool call
    /// that takes an hour (a build, the app's own `wait_for_event`) is not silence.
    public var silence: Duration

    public init(handshake: Duration, start: Duration, load: Duration, silence: Duration) {
        self.handshake = handshake
        self.start = start
        self.load = load
        self.silence = silence
    }

    /// Every runtime's, unless its launch says otherwise.
    public static let standard = RuntimeDeadlines(handshake: .seconds(120), start: .seconds(120),
                                                  load: .seconds(300), silence: .seconds(20 * 60))

    public enum Phase: String, Sendable, Hashable {
        case handshake, start, load, turn
    }

    public subscript(phase: Phase) -> Duration {
        switch phase {
        case .handshake: handshake
        case .start: start
        case .load: load
        case .turn: silence
        }
    }
}

/// A runtime that did not answer within its deadline (#166). The process is still there
/// when this is thrown; ending it is the caller's.
public struct RuntimeDidNotAnswer: Error, Sendable, Hashable, CustomStringConvertible {
    public var phase: RuntimeDeadlines.Phase
    public var after: Duration

    public init(phase: RuntimeDeadlines.Phase, after: Duration) {
        self.phase = phase
        self.after = after
    }

    /// What it did not do, to follow the runtime's name: "did not answer its handshake in
    /// 2 minutes".
    public var words: String {
        let what = switch phase {
        case .handshake: "did not answer its handshake"
        case .start: "did not start a conversation"
        case .load: "did not pick its conversation back up"
        case .turn: "said nothing"
        }
        return "\(what) in \(Self.span(after))"
    }

    public var description: String { "the runtime \(words)" }

    /// A duration as a person says it: "2 minutes", "90 seconds", "a moment" for a test's
    /// milliseconds.
    public static func span(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds < 1 { return "a moment" }
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "a minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "a second" : "\(seconds) seconds"
    }
}
