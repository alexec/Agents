import AgentsKitCore
import AppKit
import SwiftUI

// Draws every size of the Needs you widget, in each of its states, to PNGs beside this
// folder (#192). Run by render.sh; see the README there for what these images are and are not.

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let now = Date()

func session(_ title: String, _ project: String, _ wanted: String?, _ kind: Need.Kind?, minutes: Double) -> AttentionSnapshotSession {
    AttentionSnapshotSession(id: UUID(), project: project, title: title, wanted: wanted, kind: kind,
                             since: now.addingTimeInterval(-minutes * 60))
}

let pool: [AttentionSnapshotSession] = [
    session("Fix the widget", "api", "Which branch should this go on, main or the release branch that ships on Friday?", .elicitation, minutes: 0.5),
    session("Rename the store", "agents", "Run swift test in Packages/AgentsKit", .permission, minutes: 4),
    session("Review the login page", "web", "The tests pass; the copy on the second step needs a person to read it", .report, minutes: 12),
    session("Bound the turn index", "agents", nil, nil, minutes: 38),
    session("Upgrade swift-nio", "relay", "May I edit Package.resolved?", .permission, minutes: 75),
    session("Draft the release notes", "docs", "Which of these three should lead?", .elicitation, minutes: 140),
    session("Untitled", "scratch", "Done", nil, minutes: 300),
    session("Profile the sidebar", "agents", "Found it: the row re-reads the store on every redraw", .report, minutes: 600),
    session("Tidy the fixtures", "web", nil, nil, minutes: 1500),
    session("Pair the iPad", "remote", "Scan the code on the Mac", .elicitation, minutes: 2900),
    session("Split the daemon", "agents", "Write to /usr/local/bin?", .permission, minutes: 4400),
    session("Move the docs", "docs", nil, nil, minutes: 9000),
]

func entry(waiting: Int, stale: Bool = false) -> AttentionEntry {
    let written = stale ? now.addingTimeInterval(-40 * 60) : now
    return AttentionEntry(date: now, snapshot: AttentionSnapshot(
        writtenAt: written, total: waiting,
        sessions: Array(pool.prefix(min(waiting, AttentionSnapshot.rowLimit)))))
}

// Points of the content area at each size, as on a 6.1-inch iPhone and an 11-inch iPad,
// before the system's 16-point margins.
let sizes: [(AttentionSnapshot.Size, String, CGSize)] = [
    (.small, "small", CGSize(width: 158, height: 158)),
    (.medium, "medium", CGSize(width: 338, height: 158)),
    (.large, "large", CGSize(width: 338, height: 354)),
    (.extraLarge, "extra-large", CGSize(width: 715, height: 330)),
]

@MainActor
func draw(_ e: AttentionEntry, _ size: AttentionSnapshot.Size, _ points: CGSize, scheme: ColorScheme, to name: String) {
    let view = AttentionLayout(entry: e, size: size)
        .padding(16)
        .frame(width: points.width, height: points.height)
        .background(Paper.ground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(12)
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("could not draw \(name)")
    }
    try! png.write(to: out.appendingPathComponent("\(name).png"))
    print(name)
}

MainActor.assumeIsolated {
    for (size, name, points) in sizes {
        for waiting in [0, 1, 5, 15] {
            draw(entry(waiting: waiting), size, points, scheme: .light, to: "\(name)-\(waiting)")
        }
    }
    for (size, name, points) in sizes where size == .large || size == .extraLarge {
        draw(AttentionEntry(date: now, snapshot: nil), size, points, scheme: .light, to: "\(name)-unknown")
        draw(entry(waiting: 15, stale: true), size, points, scheme: .light, to: "\(name)-stale")
        draw(entry(waiting: 15), size, points, scheme: .dark, to: "\(name)-15-dark")
        TextStep.scale = 1.4   // roughly the largest non-accessibility text size
        draw(entry(waiting: 15), size, points, scheme: .light, to: "\(name)-15-larger-text")
        TextStep.scale = 1
    }
}
