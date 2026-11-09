#if DEBUG
import AgentsKitCore
import Foundation

/// The walk socket's `notify` command (#4140), on the Mac and the Remote: a host's
/// notification, applied to the window's model as if its host had sent it, so a walk can
/// show what only a live host makes, such as a live tile's frames while nobody is at the
/// Mac (the host sends them only to a client in front).
///
///     {"cmd": "notify", "method": "live/frame", "params": {…}}
@MainActor
enum WalkNotify {
    /// The window's model, set when it starts.
    static var model: AgentsModel?

    static func perform(_ request: [String: Any]) -> [String: Any] {
        guard let method = request["method"] as? String else { return ["ok": false, "error": "want a method"] }
        guard let model else { return ["ok": false, "error": "no model yet"] }
        var params: JSONValue?
        if let raw = request["params"], !(raw is NSNull) {
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return ["ok": false, "error": "params are not JSON"]
            }
            params = value
        }
        return model.apply(method, params) ? ["ok": true, "did": "applied \(method)"] : ["ok": false, "error": "the model does not know \(method)"]
    }
}
#endif
