// Real mouse and keyboard synthesis (#3004, US1, research R2): CGEventPost, tagged so a
// later touch filter (US3) can tell this binary's own input from the person's real one.
import CoreGraphics
import Foundation

/// Marks every event this binary posts, in its eventSourceUserData, so a listen-only
// CGEventTap elsewhere (US3) can filter them out from a real touch.
let agentsDriveMarker: Int64 = 0x41_44_52_56 // "ADRV"

private func tagged(_ event: CGEvent) -> CGEvent {
    event.setIntegerValueField(.eventSourceUserData, value: agentsDriveMarker)
    return event
}

func synthesizeClick(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
    tagged(down).post(tap: .cghidEventTap)
    tagged(up).post(tap: .cghidEventTap)
}

/// Sent as Unicode, not key codes, so it carries any character the agent asks for
/// regardless of keyboard layout (the same trick CGEventKeyboardSetUnicodeString exists for).
func synthesizeType(_ text: String) {
    for scalar in text.unicodeScalars {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
        var units: [UniChar] = Array(String(scalar).utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        tagged(down).post(tap: .cghidEventTap)
        tagged(up).post(tap: .cghidEventTap)
    }
}

/// Named keys drive_screen's `key` action takes, mapped to their virtual keycodes
/// (Carbon's long-standing, still correct, numbering).
private let namedKeys: [String: CGKeyCode] = [
    "return": 0x24, "enter": 0x24, "tab": 0x30, "escape": 0x35, "space": 0x31,
    "backspace": 0x33, "delete": 0x33, "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
]

func synthesizeKey(_ name: String) -> Bool {
    let lowered = name.lowercased()
    let code: CGKeyCode
    if let named = namedKeys[lowered] {
        code = named
    } else if lowered.count == 1 {
        synthesizeType(lowered)
        return true
    } else {
        return false
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
    tagged(down).post(tap: .cghidEventTap)
    tagged(up).post(tap: .cghidEventTap)
    return true
}
