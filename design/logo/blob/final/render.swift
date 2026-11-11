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
