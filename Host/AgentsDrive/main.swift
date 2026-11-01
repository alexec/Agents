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
//   {"action":"screenshot"}
//   {"action":"click","app":"TextEdit","label":"Save"}
//   {"action":"click","app":"TextEdit","x":120,"y":80}
//   {"action":"type","app":"TextEdit","text":"hello"}
//   {"action":"key","app":"TextEdit","keyName":"return"}
//   {"action":"read","app":"TextEdit"}
//
// Each answered with {"ok":true, ...} or {"ok":false,"error":"..."}. It ends when its
// standard input closes, which is when the agent's lease on "screen" is let go.
import Foundation

signal(SIGPIPE, SIG_IGN)

let out = FileHandle.standardOutput
func reply(_ body: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: body) else { return }
    data.append(0)
    out.write(data)
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
    switch action {
    case "screenshot":
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
        synthesizeType(text)
        reply(["ok": true])

    case "key":
        guard let keyName = json["keyName"] as? String, synthesizeKey(keyName) else {
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

    default:
        reply(["ok": false, "error": "unknown action \"\(action)\"."])
    }
}
exit(0)
