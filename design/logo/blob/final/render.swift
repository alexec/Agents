// The one renderer for every mark (#4615): scripts/design.sh marks compiles it and calls it.
//   render in.svg size out.png          the SVG as a PNG of size by size, keeping transparency
//                                       (Quick Look fills it white)
//   render ico out.ico in.png [in.png…] the PNGs in one .ico, with ImageIO (the platform writes ICO)
import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("render: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let a = CommandLine.arguments
// render same a.png b.png most: exit 0 when both are the same size and no channel of any pixel
// differs by more than most (of 255). A Mac's GPU and CI's virtual one draw the shadow and
// encode the JPEG a few levels apart, so the check compares pixels, not bytes (#4615).
if a.count == 5, a[1] == "same", let most = Int(a[4]) {
    func pixels(_ path: String) -> (Int, Int, [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { fail("cannot draw \(path)") }
        return (w, h, data)
    }
    let (one, two) = (pixels(a[2]), pixels(a[3]))
    guard one.0 == two.0, one.1 == two.1 else {
        print("\(one.0)×\(one.1) against \(two.0)×\(two.1)")
        exit(1)
    }
    let worst = zip(one.2, two.2).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    print("at most \(worst)/255 apart")
    exit(worst <= most ? 0 : 1)
}
if a.count >= 4, a[1] == "ico" {
    let url = URL(fileURLWithPath: a[2]) as CFURL
    let inputs = Array(a[3...])
    guard let out = CGImageDestinationCreateWithURL(url, "com.microsoft.ico" as CFString, inputs.count, nil) else {
        fail("cannot write \(a[2])")
    }
    for path in inputs {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
        CGImageDestinationAddImage(out, image, nil)
    }
    guard CGImageDestinationFinalize(out) else { fail("cannot write \(a[2])") }
    exit(0)
}
guard a.count == 4, let image = NSImage(contentsOfFile: a[1]), let size = Int(a[2]) else {
    fail("usage: render in.svg size out.png | render ico out.ico in.png…")
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
do {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
} catch {
    fail("cannot write \(a[3]): \(error)")
}
