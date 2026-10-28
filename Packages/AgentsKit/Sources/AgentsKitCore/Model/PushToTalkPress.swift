import Foundation

/// One press of the dictate button, held to talk (#2521, #2753).
///
/// Held past `holdTime`, the press starts dictation. Let go where it began and the prompt
/// is sent. Dragged more than `cancelDistance` away and let go there, it is cancelled, as
/// in Messages: dictation stops and nothing is sent. Dragged back before letting go, it
/// sends after all.
public struct PushToTalkPress: Sendable, Equatable {
    /// How a held press ends.
    public enum Ending: Sendable, Equatable {
        case send
        case cancel
    }

    public static let holdTime: Duration = .milliseconds(400)
    /// How far the finger or pointer may go from where it pressed before letting go cancels.
    public static let cancelDistance = 50.0

    /// The press was held long enough to start dictation.
    public private(set) var isHeld = false
    /// Where the press is now is far enough away that letting go cancels.
    public private(set) var isDraggedOff = false

    public init() {}

    /// The press moved, by this much from where it began.
    public mutating func moved(by x: Double, _ y: Double) {
        isDraggedOff = (x * x + y * y).squareRoot() > Self.cancelDistance
    }

    /// The press has lasted `holdTime`. True when dictation starts: not when it was
    /// dragged off first.
    public mutating func held() -> Bool {
        guard !isHeld, !isDraggedOff else { return false }
        isHeld = true
        return true
    }

    /// The press was let go, this far from where it began. Nil when it was never held:
    /// that is a tap, and the button's own action has it.
    public mutating func ended(at x: Double, _ y: Double) -> Ending? {
        moved(by: x, y)
        defer { self = PushToTalkPress() }
        guard isHeld else { return nil }
        return isDraggedOff ? .cancel : .send
    }
}

/// Waits for `work`, but no longer than `limit`. True when the work finished in time.
/// The work goes on if it did not; whatever it changes after that is the caller's to ignore.
public func waitAtMost(_ limit: Duration, for work: @escaping @Sendable () async -> Void) async -> Bool {
    let first = FirstOfTwo()
    return await withCheckedContinuation { continuation in
        first.set(continuation)
        Task {
            await work()
            first.resume(true)
        }
        Task {
            try? await Task.sleep(for: limit)
            first.resume(false)
        }
    }
}

/// Resumes a continuation once, with whichever answer comes first.
private final class FirstOfTwo: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
