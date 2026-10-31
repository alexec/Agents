// The whole screen, downscaled and JPEG-compressed, well under an ordinary chat image's
// size (#3004, US1, research R3). CGWindowListCreateImage is obsolete on this project's
// deployment target (macOS 27): ScreenCaptureKit's SCScreenshotManager.captureImage is its
// one-shot-still replacement, needing Screen Recording granted once (beside Accessibility).
import AppKit
import Foundation
import ScreenCaptureKit

private let maxDimension: CGFloat = 1280

func captureScreenshotBase64() -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    // Written once, by the Task, before semaphore.signal(); read only after
    // semaphore.wait() returns: the semaphore is the synchronization the compiler cannot
    // see across the Task boundary.
    nonisolated(unsafe) var result: String?
    Task {
        result = await captureScreenshotAsync()
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

private func captureScreenshotAsync() async -> String? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let display = content.displays.first else { return nil }
    let scale = min(1, maxDimension / CGFloat(max(display.width, display.height)))
    let config = SCStreamConfiguration()
    config.width = Int(CGFloat(display.width) * scale)
    config.height = Int(CGFloat(display.height) * scale)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
    return data.base64EncodedString()
}
