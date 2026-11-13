// agents-drive (#3004, US1): the Go agentsd's driver of another app's own screen, mouse
// and keyboard, for drive_screen. ApplicationServices/CoreGraphics/IOKit need cgo, which Go
// avoids everywhere else, so the Go host runs this beside it in Agents Host's Helpers, the
// same reason agents-watch exists for FSEvents (research R1, R11).
//
// One command in on standard input, one reply out on standard output, both a single JSON
// object followed by a NUL byte (research R1's framing, reused from agents-watch's own
// NUL-terminated frames, carrying a JSON payload here since a typed field can hold any
// text, including a NUL-free label or a typed sentence with its own punctuation):
//
//   {"action":"access"}
//   {"action":"screenshot"}
//   {"action":"frame"}
//   {"action":"click","app":"TextEdit","label":"Save"}
//   {"action":"click","app":"TextEdit","x":120,"y":80}
//   {"action":"type","app":"TextEdit","text":"hello"}
//   {"action":"key","app":"TextEdit","keyName":"return"}
//   {"action":"read","app":"TextEdit"}
//   {"action":"front","pid":4242}
//
// The mouse and keyboard post to the whole session, so `type`, `key` and `click` by x,y
// first bring `app` to the front and refuse when it does not get there (frontmost(app:)).
//
// "front" (#5208) brings the app with that pid to the front, by pid and not by name: the
// agents' Google Chrome and the person's own have the same name. It answers with the pid
// that was in front before, so the daemon can bring that app back when the person is done.
// It is the person's step, not the agent's, so it does not watch for their touch.
//
// Each answered with {"ok":true, ...} or {"ok":false,"error":"..."}. It ends when its
// standard input closes, which is when the agent's lease on "screen" is let go.
// "access" (#3004, US2) is the Accessibility gate: it reports whether this process is
// trusted, triggering macOS's own grant prompt on first use if not, before the daemon
// ever takes the "screen" lease (FR-005).
//
// Pause on touch (#3004, US3): besides its replies, it says {"touch":true} by itself the
// moment the person touches the real mouse or keyboard (TouchFilter.swift), once per
// command. A `type` the person touched part way stops there and answers
// {"ok":false,"touched":true,"typed":<characters typed>}; the daemon sends the rest on
// Resume.
import Foundation

signal(SIGPIPE, SIG_IGN)

let out = FileHandle.standardOutput
/// The tap's thread says a touch while a reply may be on its way: one frame at a time.
let outLock = NSLock()
func reply(_ body: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: body) else { return }
    data.append(0)
    outLock.lock()
    out.write(data)
    outLock.unlock()
}

func readFrames(_ body: (Data) -> Void) {
    let input = FileHandle.standardInput
    var buffer = Data()
    while true {
        let chunk = input.availableData
        if chunk.isEmpty { return } // stdin closed: the host let this process go.
        buffer.append(chunk)
        while let nul = buffer.firstIndex(of: 0) {
            body(buffer[..<nul])
            buffer.removeSubrange(...nul)
        }
    }
}

readFrames { frame in
    guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
          let action = json["action"] as? String else {
        reply(["ok": false, "error": "a command must be {\"action\": ...}."])
        return
    }
    let app = json["app"] as? String ?? ""
    // The live tile's frame (US4) is not the agent's command: the person's touch between
    // two of those is said by the last command's arming, not again every few seconds.
    if action != "frame" && action != "front" { touchWatch.arm() }
    switch action {
    case "access":
        // Desktop control's Accessibility gate (#3004, US2, FR-005): triggers macOS's own
        // grant prompt on first use if not already granted.
        reply(["ok": true, "trusted": axIsTrusted()])

    case "screenshot", "frame":
        guard let image = captureScreenshotBase64() else {
            reply(["ok": false, "error": "could not capture the screen."])
            return
        }
        reply(["ok": true, "image": image])

    case "click":
        if let label = json["label"] as? String, !label.isEmpty {
            guard let pid = pid(ofApp: app) else {
                reply(["ok": false, "error": "no running app named \"\(app)\"."])
                return
            }
            guard axPress(pid: pid, label: label) else {
                reply(["ok": false, "error": "nothing pressable matched \"\(label)\"."])
                return
            }
            reply(["ok": true])
        } else if let x = json["x"] as? Double, let y = json["y"] as? Double {
            if let refused = frontmost(app: app) {
                reply(["ok": false, "error": refused])
                return
            }
            synthesizeClick(x: x, y: y)
            reply(["ok": true])
        } else {
            reply(["ok": false, "error": "click needs a label or x,y."])
        }

    case "type":
        guard let text = json["text"] as? String else {
            reply(["ok": false, "error": "type needs text."])
            return
        }
        if let refused = frontmost(app: app) {
            reply(["ok": false, "error": refused])
            return
        }
        let typed = synthesizeType(text)
        if typed < text.unicodeScalars.count {
            reply(["ok": false, "touched": true, "typed": typed])
            return
        }
        reply(["ok": true])

    case "key":
        guard let keyName = json["keyName"] as? String, !keyName.isEmpty else {
            reply(["ok": false, "error": "key needs a keyName it knows."])
            return
        }
        if let refused = frontmost(app: app) {
            reply(["ok": false, "error": refused])
            return
        }
        guard synthesizeKey(keyName) else {
            reply(["ok": false, "error": "key needs a keyName it knows."])
            return
        }
        reply(["ok": true])

    case "read":
        guard let pid = pid(ofApp: app) else {
            reply(["ok": false, "error": "no running app named \"\(app)\"."])
            return
        }
        reply(["ok": true, "tree": axDump(pid: pid)])

    case "front":
        guard let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0 else {
            reply(["ok": false, "error": "front needs a pid."])
            return
        }
        let previous = frontmostPid()
        if let refused = frontmost(pid: pid) {
            reply(["ok": false, "error": refused, "previous": previous])
            return
        }
        reply(["ok": true, "previous": previous])

    default:
        reply(["ok": false, "error": "unknown action \"\(action)\"."])
    }
}
exit(0)
