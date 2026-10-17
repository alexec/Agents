import Foundation
import Testing
@testable import AgentsKitCore

/// A walk prints every element's frame in whole points; a frame no `Int` holds is zero, not
/// a trap (#1307: the Remote's walk crashed on `Int(box.minX)` twice).
@Suite("A walk's frame in whole points")
struct WalkBoxTests {
    @Test func anOrdinaryFrameIsKept() {
        let box = WalkBox(CGRect(x: 12.7, y: -3.2, width: 300, height: 44.9))
        #expect(box == WalkBox(x: 12, y: -3, width: 300, height: 44))
        #expect(box.text == "@12,-3 300x44")
        #expect(box.dictionary == ["x": 12, "y": -3, "width": 300, "height": 44])
    }

    @Test(arguments: [
        CGRect.null,
        CGRect.infinite,
        CGRect(x: -1e300, y: 0, width: 10, height: 10),
        CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
        CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
    ])
    func aFrameNoIntHoldsIsZero(_ rect: CGRect) {
        #expect(WalkBox(rect) == .zero)
    }
}
