#if DEBUG
import Foundation

/// The walk socket's `voice` command (#2322), on the Mac and the Remote: voice mode with no
/// microphone and no sound, so a walk on a scratch set-up asks for no permission and says
/// nothing out loud on the person's speakers.
///
///     {"cmd": "voice"}                                  what voice mode is doing, and what it said
///     {"cmd": "voice", "enable": true}                  Settings' switch, without the window
///     {"cmd": "voice", "walk": true}                    no microphone, no sound, from now on
///     {"cmd": "voice", "heard": "Fix the bug."}         words as if heard, then the pause
///     {"cmd": "voice", "wake": "Hey Agents, hi."}       words as if the wake listener heard them (Mac, #2420)
@MainActor
enum VoiceWalk {
    static func perform(_ request: [String: Any]) -> [String: Any] {
        let voice = VoiceMode.shared
        if let enable = request["enable"] as? Bool {
            WindowDefaults.store.set(enable, forKey: VoiceSettings.onKey)
        }
        if request["walk"] as? Bool == true {
            voice.isWalked = true
        }
        if let heard = request["heard"] as? String {
            voice.walkHeard(heard)
        }
        var woke: Bool?
        #if os(macOS)
        if let wake = request["wake"] as? String {
            woke = WakeListener.shared.walkHeard(wake)
        }
        #endif
        return [
            "ok": true,
            "enabled": WindowDefaults.store.bool(forKey: VoiceSettings.onKey),
            "agentID": voice.agentID?.uuidString ?? "",
            "phase": "\(voice.phase)",
            "heard": voice.heard,
            "waitingForReply": voice.isWaitingForReply,
            "said": voice.said,
            "problem": voice.problem ?? "",
            "woke": woke as Any,
        ]
    }
}
#endif
