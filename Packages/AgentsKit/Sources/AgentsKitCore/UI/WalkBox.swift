import Foundation

/// An element's frame as a walk prints it, in whole points (#1172, #1182, #1307).
///
/// An accessibility frame can be null (`CGRect.null` is at infinity), infinite, or huge but
/// finite (`CGRect.infinite`), and `Int(_:)` traps on a value it cannot hold: the Remote's
/// walk crashed twice on one before this. Any such frame is zero, which a walk reads as "no
/// frame".
public struct WalkBox: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    /// The largest coordinate taken as it is; any screen is far smaller.
    public static let limit = 1_000_000.0

    public static let zero = WalkBox(x: 0, y: 0, width: 0, height: 0)

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        let values = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
        guard values.allSatisfy({ $0.isFinite && abs($0) < Self.limit }) else {
            self = .zero
            return
        }
        self.init(x: Int(values[0]), y: Int(values[1]), width: Int(values[2]), height: Int(values[3]))
    }

    /// What a walk's JSON answers carry.
    public var dictionary: [String: Int] { ["x": x, "y": y, "width": width, "height": height] }

    /// What a walk's tree lines carry: `@x,y wxh`.
    public var text: String { "@\(x),\(y) \(width)x\(height)" }
}
