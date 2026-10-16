// Records one window, by its CGWindowID, to a .mov until it is sent SIGINT or SIGTERM.
// It records the window even when it is behind other windows, and without the cursor. It
// records every window of the window's process, cropped to that window, so its menus and
// popovers are in the picture, and no other process's windows are, not even another copy of
// the same app.
//
//   record <window id> <out.mov>
//
// When the first frame is written, it prints `start <unix time>`. make.py places every step
// marker and every narration line from that time.
import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit

_ = NSApplication.shared
setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
guard args.count == 3, let windowID = CGWindowID(args[1]) else {
    print("usage: record <window id> <out.mov>"); exit(2)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    func recordingOutputDidStartRecording(_ r: SCRecordingOutput) {
        print("start \(Date().timeIntervalSince1970)")
    }
    func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) { print("failed: \(e)"); exit(1) }
    func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) { print("done"); exit(0) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stopped: \(error)"); exit(1) }
}

let delegate = Delegate()
var stream: SCStream?
var signalSources: [DispatchSourceSignal] = []

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Task {
            try? await stream?.stopCapture()
            try? await Task.sleep(for: .seconds(10))
            print("timed out finishing"); exit(1)
        }
    }
    source.resume()
    signalSources.append(source)
}

Task { do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        print("no window \(windowID)"); exit(1)
    }
    guard let app = window.owningApplication,
          let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else {
        print("no app or display for window \(windowID)"); exit(1)
    }
    // Only this process's windows: a copy of the app with the same bundle id (the person's
    // own window) must never be in the picture, even when it is in front.
    let pid = app.processID
    let own = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
    let filter = SCContentFilter(display: display, including: own)
    let config = SCStreamConfiguration()
    let scale = Int(filter.pointPixelScale)
    config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    config.width = Int(window.frame.width) * scale
    config.height = Int(window.frame.height) * scale
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = false
    let s = SCStream(filter: filter, configuration: config, delegate: delegate)
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = out
    rc.outputFileType = .mov
    rc.videoCodecType = .h264
    try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: delegate))
    stream = s
    try await s.startCapture()
    // A popover or menu opened later is a new window: take it in as it appears.
    var seen = Set(own.map(\.windowID))
    while true {
        try await Task.sleep(for: .milliseconds(500))
        guard let now = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { continue }
        let mine = now.windows.filter { $0.owningApplication?.processID == pid }
        let ids = Set(mine.map(\.windowID))
        if ids != seen {
            seen = ids
            try? await s.updateContentFilter(SCContentFilter(display: display, including: mine))
        }
    }
} catch { print("error: \(error)"); exit(1) }
}

RunLoop.main.run()
