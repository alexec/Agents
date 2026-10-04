import AgentsKitCore
import Foundation

/// The mode last chosen for each runtime, held on the Mac rather than in a window (029).
///
/// A runtime remembers its own model and effort, so what it offers first is already the
/// same for every window and every phone. The mode it does not remember, which is why
/// the Mac's window used to, in its own defaults — where a phone could not read it and
/// a scratch copy of the app wrote over it. Here it is one file per root.
///
/// One file, read whole and written whole, the way the option cache is. An entry this
/// build cannot read is left where it is: a later build may understand it, and throwing
/// away something we merely do not recognise is not ours to do.
public struct ModeStore: Sendable {
    private struct Entry: Codable {
        var mode: JSONValue
        /// ISO-8601, as written; for a person reading the file, not for any rule here.
        var chosenAt: String?
    }

    private let locations: StoreLocations
    private let now: @Sendable () -> Date

    public init(locations: StoreLocations, now: @escaping @Sendable () -> Date = { Date() }) {
        self.locations = locations
        self.now = now
    }

    /// Every mode this build can read, by runtime id.
    public func remembered() -> DaemonAPI.RememberedModes {
        raw().compactMapValues { (try? $0.decode(Entry.self))?.mode }
    }

    /// Remember this mode for this runtime. Answers whether anything changed, so the
    /// windows are told only when there is news.
    @discardableResult
    public func remember(_ mode: JSONValue, for runtimeID: String) throws -> Bool {
        var file = raw()
        if (try? file[runtimeID]?.decode(Entry.self))?.mode == mode { return false }
        file[runtimeID] = try JSONValue.encoding(Entry(mode: mode, chosenAt: now().formatted(.iso8601)))
        try write(file)
        return true
    }

    private func raw() -> [String: JSONValue] {
        StoreFile.load([String: JSONValue].self, at: locations.modes, empty: [:],
                       meaning: "every runtime starts in its own default mode")
    }

    private func write(_ file: [String: JSONValue]) throws {
        try StoreFile.write(try StoreCoding.encoder.encode(file), to: locations.modes)
    }
}
