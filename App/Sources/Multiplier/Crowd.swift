import SwiftUI

/// The crowd over the Multiplier (#3985): one light-blue Blob for each engineer the agents
/// equal, and you in front, in white. 3.2× is three Blobs and a fourth at 20%; `— ×` is you
/// alone. Past 1,000 one Blob is 10 engineers, and a line says so.
///
/// The band does not grow: with more Blobs, they get smaller and pack closer, in rows that
/// go back and up around you. A new whole engineer pops in at the back; a revert takes one
/// away; now and then a few blink. Under Reduce Motion they appear with no pop and none
/// blinks.
///
/// The engineers are drawn in one `Canvas` (a view each costs too much at 1,000), and only
/// your Blob is a live `Blob` with eyes that look around. The layout is the approved mock's,
/// `specs/3901-multiplier/mock.html`, in points.
struct Crowd: View {
    /// The Multiplier; nil when there is none yet.
    var multiplier: Double?

    static let height: CGFloat = 190
    /// The most Blobs drawn; past it, one Blob is `bigEach` engineers.
    static let cap = 1000
    static let bigEach = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var width: CGFloat = 0
    @State private var layout = CrowdLayout.empty
    /// When each Blob that is new pops in, by its place in the crowd.
    @State private var popAt: [Int: Date] = [:]
    @State private var popsUntil = Date.distantPast
    @State private var blinking: Set<Int> = []
    @State private var youLook: CGVector = .zero
    @State private var youBlink = false
    @State private var settled = false

    private var count: CrowdCount { CrowdCount(multiplier: multiplier ?? 0) }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || popsUntil < .now)) { timeline in
            Canvas { context, _ in draw(in: &context, at: timeline.date) }
        }
        .accessibilityHidden(true)
        .overlay(alignment: .topLeading) { you }
        .overlay(alignment: .bottomTrailing) {
            if count.each > 1 {
                Text("each Blob is \(count.each) engineers")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: width) { relayout() }
        .onChange(of: count) { old, new in
            relayout()
            pop(from: old.blobs, to: new.blobs)
        }
        .onAppear { relayout() }
        // The page sets the last figures it showed as it opens; those are no news.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            settled = true
        }
        .task(id: reduceMotion) { await blink() }
        .task(id: reduceMotion) { await lookAround() }
    }

    /// Your Blob, in front, with the Huddle's live eyes.
    private var you: some View {
        let scale = layout.youScale
        return Blob(fill: .white, look: youLook, blinking: youBlink)
            .frame(width: Blob.size.width * scale, height: Blob.size.height * scale)
            .position(x: width / 2, y: Self.height - 2 - Blob.size.height / 2 * scale)
            .animation(.spring(duration: 0.4), value: youLook)
            .accessibilityHidden(true)
    }

    private func relayout() {
        layout = CrowdLayout(blobs: count.blobs, width: width, height: Self.height - 20)
    }

    /// New Blobs pop in one after another over about a second, as the number counts up.
    private func pop(from old: Int, to new: Int) {
        guard settled, !reduceMotion, new > old else { return }
        let now = Date.now
        let step = min(1.0 / Double(new - old), 0.15)
        for index in old..<new {
            popAt[index] = now.addingTimeInterval(Double(index - old) * step)
        }
        popsUntil = now.addingTimeInterval(Double(new - old) * step + Self.popTime)
        popAt = popAt.filter { $0.key < new }
    }

    private static let popTime = 0.5

    private func draw(in context: inout GraphicsContext, at date: Date) {
        let dark = colorScheme == .dark
        let fraction = count.fraction
        for index in layout.drawingOrder {
            let place = layout.places[index]
            var scale = place.scale
            if !reduceMotion, let start = popAt[index] {
                let k = date.timeIntervalSince(start) / Self.popTime
                if k < 0 { continue }
                if k < 1 { scale *= 1.25 * k - 0.25 * k * k * k + sin(k * .pi) * 0.15 }
            }
            let faint = index == count.blobs - 1 && fraction > 0
            var blob = context
            blob.opacity = faint ? max(fraction, 0.12) : 1
            blob.translateBy(x: place.point.x, y: place.point.y)
            blob.rotate(by: .radians((place.seed - 0.5) * 0.18))
            blob.scaleBy(x: scale, y: scale)
            Self.drawBlob(in: blob, fill: Self.fill(place.seed, dark: dark),
                          look: (place.seed - 0.5) * 1.6, shut: !reduceMotion && blinking.contains(index))
        }
    }

    /// One engineer, in the Blob's own units, centred on the origin.
    private static func drawBlob(in context: GraphicsContext, fill: Color, look: Double, shut: Bool) {
        context.stroke(shape, with: .color(Blob.outline), style: StrokeStyle(lineWidth: 56, lineJoin: .round))
        context.fill(shape, with: .color(fill))
        for x in [-92.0, 92.0] {
            let height = shut ? 12.0 : 124.0
            let eye = CGRect(x: x + look * 18 - 46, y: -30 - height / 2, width: 92, height: height)
            context.fill(Path(ellipseIn: eye), with: .color(Blob.ink))
        }
        context.stroke(smile, with: .color(Blob.ink), style: StrokeStyle(lineWidth: 28, lineCap: .round))
    }

    private static let shape = BlobShape().path(in: CGRect(origin: CGPoint(x: -Blob.size.width / 2, y: -Blob.size.height / 2),
                                                          size: Blob.size))
    private static let smile = Path { path in
        path.move(to: CGPoint(x: -64, y: 80))
        path.addQuadCurve(to: CGPoint(x: 64, y: 80), control: CGPoint(x: 0, y: 150))
    }

    /// A light blue a little different for each engineer, so the crowd is not flat.
    private static func fill(_ seed: Double, dark: Bool) -> Color {
        dark
            ? Color(hue: (212 + seed * 10) / 360, saturation: 0.46 - seed * 0.13, brightness: 0.91 + seed * 0.03)
            : Color(hue: (210 + seed * 12) / 360, saturation: 0.28 - seed * 0.12, brightness: 1)
    }

    /// A few at a time, now and then; you too, sometimes.
    private func blink() async {
        blinking = []
        youBlink = false
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.9))
            if Task.isCancelled { return }
            let blobs = max(count.blobs, 1)
            blinking = Set((0..<Int.random(in: 1...5)).map { _ in Int.random(in: 0..<blobs) })
            youBlink = Double.random(in: 0..<1) < 0.25
            try? await Task.sleep(for: .milliseconds(140))
            blinking = []
            youBlink = false
        }
    }

    /// Your eyes look somewhere else now and then.
    private func lookAround() async {
        youLook = .zero
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 1.4...3.2)))
            if Task.isCancelled { return }
            let angle = Double.random(in: 0..<(2 * .pi))
            let length = Double.random(in: 0...0.9)
            youLook = CGVector(dx: cos(angle) * length, dy: sin(angle) * length * 0.6)
        }
    }
}

/// How many Blobs a Multiplier is: the whole part, and one more, faint, for the fraction.
struct CrowdCount: Equatable {
    /// Engineers for each Blob: 1, or `Crowd.bigEach` past `Crowd.cap`.
    let each: Int
    let blobs: Int
    /// How opaque the last Blob is, or 0 when the last is a whole one.
    let fraction: Double

    init(multiplier: Double) {
        let value = max(multiplier, 0)
        each = value > Double(Crowd.cap) ? Crowd.bigEach : 1
        let scaled = value / Double(each)
        let whole = Int(scaled.rounded(.down))
        let part = scaled - Double(whole)
        fraction = part > 0.05 ? part : 0
        blobs = whole + (fraction > 0 ? 1 : 0)
    }
}

/// Where each engineer stands: a mound of rows around you, the nearest places first, so 3
/// is a Huddle and 300 is a crowd in a stadium.
struct CrowdLayout {
    struct Place {
        let point: CGPoint
        let scale: CGFloat
        /// A fixed number from 0 to 1 for this place, for its colour, tilt and look.
        let seed: Double
    }

    var places: [Place]
    /// The indices of `places` from the back row to the front, the order to draw in.
    var drawingOrder: [Int]
    /// Your Blob's scale: the Huddle's size with few, smaller in a big crowd.
    var youScale: CGFloat

    static let empty = CrowdLayout(places: [], drawingOrder: [], youScale: 0.135)

    init(places: [Place], drawingOrder: [Int], youScale: CGFloat) {
        self.places = places
        self.drawingOrder = drawingOrder
        self.youScale = youScale
    }

    init(blobs: Int, width: CGFloat, height: CGFloat) {
        guard blobs > 0, width > 0 else {
            self = .empty
            return
        }
        // A half ellipse with you at the middle of its base.
        let a = width / 2, b = height
        let cell = min(sqrt((.pi * a * b / 2) / (CGFloat(blobs) * 0.52)) * 0.9, 70)
        let rowStep = cell * 0.52, middle = width / 2, base = height - cell * 0.45
        let rows = Int((b / rowStep).rounded(.up)) + 2, columns = Int((width / cell).rounded(.up)) + 2
        var cells: [(point: CGPoint, distance: CGFloat)] = []
        for row in 0..<rows {
            for column in -columns...columns {
                let x = middle + (CGFloat(column) + CGFloat(row % 2) * 0.5) * cell
                let y = base - CGFloat(row) * rowStep
                if x < cell / 2 || x > width - cell / 2 || y < cell / 2 { continue }
                // Your place, in front.
                if row == 0, abs(x - middle) < max(cell * 0.9, 40) { continue }
                let dx = (x - middle) / a, dy = (base - y + cell * 0.6) / b
                cells.append((CGPoint(x: x, y: y), dx * dx + dy * dy))
            }
        }
        cells.sort { $0.distance < $1.distance }
        let scale = cell / Blob.size.width * 0.86
        let size = cell
        let places = cells.prefix(blobs).enumerated().map { index, cell in
            let seed = Double((index * 9301 + 49297) % 233_280) / 233_280
            let shake = (seed * 7).truncatingRemainder(dividingBy: 1)
            let point = CGPoint(x: cell.point.x + (seed - 0.5) * size * 0.18, y: cell.point.y + (shake - 0.5) * size * 0.12)
            return Place(point: point, scale: scale, seed: seed)
        }
        self.places = places
        drawingOrder = places.indices.sorted { places[$0].point.y < places[$1].point.y }
        youScale = min(max(0.065, cell * 1.15 / Blob.size.width), 0.135)
    }
}
