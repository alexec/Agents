import Foundation
// Baseline with Foundation linked, as agentsd has it (kept live so the linker keeps it).
let data = try! JSONSerialization.data(withJSONObject: ["print": "foundation", "at": Date().description])
print(String(decoding: data, as: UTF8.self))
