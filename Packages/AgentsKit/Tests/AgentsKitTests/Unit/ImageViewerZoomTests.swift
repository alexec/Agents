import AgentsKitCore
import Foundation
import Testing

@Suite("Forge page images (#4010)")
struct ImageViewerZoomTests {
    @Test("an image larger than the room is fitted to it, keeping its shape")
    func fitsLargerImage() {
        let fitted = ImageViewerZoom.fitted(CGSize(width: 2000, height: 1000), in: CGSize(width: 1000, height: 1000))
        #expect(fitted == CGSize(width: 1000, height: 500))
    }

    @Test("an image smaller than the room is not enlarged")
    func keepsSmallImage() {
        #expect(ImageViewerZoom.fitted(CGSize(width: 200, height: 100), in: CGSize(width: 1000, height: 800))
            == CGSize(width: 200, height: 100))
    }

    @Test("no size or no room draws nothing")
    func emptySizes() {
        #expect(ImageViewerZoom.fitted(.zero, in: CGSize(width: 10, height: 10)) == .zero)
        #expect(ImageViewerZoom.fitted(CGSize(width: 10, height: 10), in: .zero) == .zero)
    }

    @Test("a pinch is free, between fitted and the most")
    func pinch() {
        #expect(ImageViewerZoom.pinched(from: 2, by: 1.25) == 2.5)
        #expect(ImageViewerZoom.pinched(from: 1, by: 0.5) == 1)
        #expect(ImageViewerZoom.pinched(from: 6, by: 3) == 8)
        #expect(ImageViewerZoom.pinched(from: 1, by: .nan) == 1)
    }

    @Test("only an https address is asked of forge/image")
    func imageURL() {
        #expect(ForgeMarkdown.imageURL(of: "https://github.com/user-attachments/assets/abc")?.host == "github.com")
        #expect(ForgeMarkdown.imageURL(of: "http://github.com/a.png") == nil)
        #expect(ForgeMarkdown.imageURL(of: "shot.png") == nil)
        #expect(ForgeMarkdown.imageURL(of: "file:///etc/passwd") == nil)
        #expect(ForgeMarkdown.imageURL(of: "data:image/png;base64,AAAA") == nil)
    }
}
