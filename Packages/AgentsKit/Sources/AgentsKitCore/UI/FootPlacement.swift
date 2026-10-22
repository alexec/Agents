import Foundation

/// When the chat, placed at its foot again and again, has come to rest there (#1287, #2210).
///
/// A lazy stack measures the rows above the end after a move to it, and each row it
/// measures moves the end. One move lands where the estimates put the foot, which after
/// a long read back is turns short of it. So the pane is placed again, a frame at a time,
/// until it reads the same a few samples running.
///
/// Each sample is how far past the furthest the pane can rest it is: negative short of
/// it, about zero at it, positive in a bounce.
public struct FootPlacement: Equatable, Sendable {
    /// How many samples running must agree.
    public let samplesAtRest: Int
    /// Whether resting counts only at the end. Opening a chat shorter than its pane rests
    /// at the top of it; going to the end of a long one rests nowhere short of the end.
    public let atTheEnd: Bool
    private var last: Double?
    private var resting = 0

    public init(samplesAtRest: Int = 3, atTheEnd: Bool) {
        self.samplesAtRest = samplesAtRest
        self.atTheEnd = atTheEnd
    }

    /// Whether the pane has come to rest, with this sample the latest.
    public mutating func rests(after pastTheEnd: Double) -> Bool {
        let still = last.map { pastTheEnd.isFinite && abs(pastTheEnd - $0) < 0.5 } ?? false
        let there = !atTheEnd || pastTheEnd > -1
        resting = still && there ? resting + 1 : 0
        last = pastTheEnd
        return resting >= samplesAtRest
    }
}
