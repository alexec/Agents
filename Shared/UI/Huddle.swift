import SwiftUI

/// The Huddle (#987, the mark of #1007): three Blobs over the empty page of a new session,
/// one white in front and two light blue behind, tilted in.
///
/// They are alive. Left alone, their eyes look around now and then and blink, and the two
/// at the back glance at the one in front. While the prompt has focus, all three look at
/// the pointer; with no pointer, or with the pointer still for about 2 s, they look down
/// at the prompt and glance along it as the person types. With Reduce Motion, the eyes
/// stay still, looking ahead.
///
/// Drawn from `Blob` three times, so one Blob can be drawn alone (#986). Decorative: it
/// says nothing VoiceOver needs.
struct Huddle: View {
    /// Whether the prompt has focus.
    var promptFocused: Bool
    /// Where the pointer is, in the global coordinate space. Nil where there is none
    /// (a phone, an iPad by touch) or while it is outside the page.
    var pointer: CGPoint?
    /// How many characters the prompt holds, for the eyes to follow along it.
    var typed: Int = 0
    var height: CGFloat = 72

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var idle: [CGVector] = [.zero, .zero, .zero]
    @State private var blinking: [Bool] = [false, false, false]
    /// The pointer has not moved for a while, so the eyes go back to the prompt.
    @State private var pointerResting = true
    @State private var frame: CGRect = .zero

    private var unit: CGFloat { height / Self.box.height }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.blobs.indices, id: \.self) { index in
                let blob = Self.blobs[index]
                Blob(fill: blob.fill, facing: blob.facing, look: look(index), blinking: blinking[index])
                    .frame(width: Blob.size.width * blob.scale * unit, height: Blob.size.height * blob.scale * unit)
                    .rotationEffect(.degrees(blob.tilt))
                    .position(x: (blob.centre.x - Self.box.minX) * unit, y: (blob.centre.y - Self.box.minY) * unit)
            }
        }
        .frame(width: Self.box.width * unit, height: height)
        .animation(.spring(duration: 0.45), value: gaze)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onChange(of: pointer) { pointerResting = false }
        // Each move starts the wait again; a still pointer gives the prompt back.
        .task(id: pointer) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { pointerResting = true }
        }
        .task(id: reduceMotion) { await lookAround() }
        .task(id: reduceMotion) { await blink() }
        .accessibilityHidden(true)
    }

    /// What decides where the eyes are, so a change to it is what animates them.
    private var gaze: [CGVector] { Self.blobs.indices.map(look) }

    /// Where blob `index` looks: x and y of at most 1, from straight ahead.
    private func look(_ index: Int) -> CGVector {
        if reduceMotion { return .zero }
        guard promptFocused else { return idle[index] }
        if let pointer, !pointerResting, frame != .zero {
            let blob = Self.blobs[index]
            let eyes = CGPoint(x: frame.minX + (blob.centre.x - Self.box.minX) * unit,
                               y: frame.minY + (blob.centre.y - 30 * blob.scale - Self.box.minY) * unit)
            let dx = pointer.x - eyes.x, dy = pointer.y - eyes.y
            let distance = max(hypot(dx, dy), 1)
            // Full turn only past a short reach, so a pointer on the Blobs is not a squint.
            let reach = min(distance / 160, 1)
            return CGVector(dx: dx / distance * reach, dy: dy / distance * reach)
        }
        // Down at the prompt, along it left to right as the words grow.
        let along = typed == 0 ? 0 : -0.7 + 1.4 * CGFloat(typed % 60) / 60
        return CGVector(dx: along, dy: 1)
    }

    /// Now and then one Blob looks somewhere else; the two at the back sometimes at the
    /// one in front.
    private func lookAround() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 1.4...3.2)))
            if Task.isCancelled { return }
            let index = Int.random(in: 0..<3)
            let roll = Double.random(in: 0..<1)
            if index < 2, roll < 0.35 {
                idle[index] = CGVector(dx: index == 0 ? 0.8 : -0.8, dy: 0.5)
            } else if roll < 0.55 {
                idle[index] = .zero
            } else {
                let angle = Double.random(in: 0..<(2 * .pi))
                let length = Double.random(in: 0.4...0.9)
                idle[index] = CGVector(dx: cos(angle) * length, dy: sin(angle) * length)
            }
        }
    }

    private func blink() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 2.5...5.5)))
            if Task.isCancelled { return }
            // Mostly one at a time; now and then all three together.
            let which = Double.random(in: 0..<1) < 0.25 ? [0, 1, 2] : [Int.random(in: 0..<3)]
            withAnimation(.easeIn(duration: 0.07)) { for index in which { blinking[index] = true } }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.easeOut(duration: 0.1)) { for index in which { blinking[index] = false } }
        }
    }

    /// One Blob of the mark, in the mark's own units (`design/logo/three-blobs/B.svg`).
    private struct Placed {
        let centre: CGPoint
        let tilt: Double
        let scale: CGFloat
        let fill: Color
        /// Where its face points: the two at the back look in, at the front one.
        let facing: CGFloat
    }

    /// In drawing order: the two at the back, then the one in front of them.
    private static let blobs = [
        Placed(centre: CGPoint(x: 300, y: 430), tilt: -8, scale: 0.5, fill: Blob.backFill, facing: 20),
        Placed(centre: CGPoint(x: 724, y: 430), tilt: 8, scale: 0.5, fill: Blob.backFill, facing: -20),
        Placed(centre: CGPoint(x: 512, y: 600), tilt: 0, scale: 0.62, fill: .white, facing: 0),
    ]

    /// The part of the mark's 1024 square the three Blobs and their outlines cover.
    private static let box = CGRect(x: 115, y: 249, width: 794, height: 548)
}

/// The app's Blob: a rounded white body, an outline, two eyes and a smile, in its own
/// units of 600 by 580 (`design/logo/blob/final/tile.svg`).
///
/// `look` moves the eyes, x and y of at most 1 from straight ahead; `blinking` closes them.
struct Blob: View {
    var fill: Color = .white
    /// How far, in its own units, the face is turned sideways.
    var facing: CGFloat = 0
    var look: CGVector = .zero
    var blinking = false

    nonisolated static let size = CGSize(width: 600, height: 580)
    static let outline = Color(red: 0x3A / 255, green: 0x78 / 255, blue: 0xE6 / 255)
    static let backFill = Color(red: 0xCF / 255, green: 0xE3 / 255, blue: 0xFF / 255)
    static let ink = Color(red: 0x0E / 255, green: 0x1A / 255, blue: 0x3A / 255)

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / Self.size.width
            let eyes = CGPoint(x: facing + look.dx * 40, y: -30 + look.dy * 32)
            ZStack {
                BlobShape().stroke(Self.outline, style: StrokeStyle(lineWidth: 56 * unit, lineJoin: .round))
                BlobShape().fill(fill)
                ForEach([-92, 92] as [CGFloat], id: \.self) { x in
                    Ellipse()
                        .fill(Self.ink)
                        .frame(width: 92 * unit, height: 124 * unit)
                        .scaleEffect(x: 1, y: blinking ? 0.08 : 1)
                        .offset(x: (x + eyes.x) * unit, y: eyes.y * unit)
                }
                Smile(facing: facing)
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: 28 * unit, lineCap: .round))
            }
        }
    }
}

/// The Blob's body: a rounded square a little wider than it is tall.
struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let point = BlobUnits(rect: rect)
        var path = Path()
        path.move(to: point(0, -290))
        path.addCurve(to: point(300, 4), control1: point(188, -290), control2: point(300, -186))
        path.addCurve(to: point(0, 290), control1: point(300, 196), control2: point(188, 290))
        path.addCurve(to: point(-300, 4), control1: point(-188, 290), control2: point(-300, 196))
        path.addCurve(to: point(0, -290), control1: point(-300, -186), control2: point(-188, -290))
        path.closeSubpath()
        return path
    }
}

private struct Smile: Shape {
    var facing: CGFloat

    func path(in rect: CGRect) -> Path {
        let point = BlobUnits(rect: rect)
        var path = Path()
        path.move(to: point(facing - 64, 80))
        path.addQuadCurve(to: point(facing + 64, 80), control: point(facing, 150))
        return path
    }
}

/// A point in the Blob's own units, centred on its middle, placed in `rect`.
private struct BlobUnits {
    let rect: CGRect

    func callAsFunction(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.midX + x * rect.width / Blob.size.width, y: rect.midY + y * rect.height / Blob.size.height)
    }
}
