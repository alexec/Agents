import Foundation
import AgentsKitCore

/// What a restart owes the events (#1219): `system.restarted`, how long nothing was
/// running, and every wait that was open over the gap told so when it next wakes.
///
/// A running daemon writes `alive.json` once a minute, and a clean stop writes its time.
/// The next start reads it: the stop time, or the last alive time after a crash, is when
/// the gap began. Events only the daemon sees (`agent.*`, `lease.*`, `mac.*`) cannot be
/// had again for that time; a wait on one is told it may have missed something, at its
/// next wake and not before, since waking it only to say so would use a turn for nothing.
extension DaemonCore {
    /// On start, after the agents are read and before anything could wake a wait: work
    /// out the gap, and mark every open wait as having been open over it.
    @discardableResult
    public func noteRestart() -> RestartGap {
        loadEventsIfNeeded()
        let at = now()
        let gap = RestartGap(at: at, alive: DaemonAliveFile.read(locations.alive))
        lastRestart = gap
        let caughtUp = gap.reason != .firstStart
        diskLookAfterRestart = caughtUp
        machineLookAfterRestart = caughtUp
        var restarts = eventState.waitRestarts ?? [:]
        let waits = agents.withEventWait.compactMap { agents[$0]?.eventWait }
        let kept = Set(waits.map(\.id.uuidString))
        restarts = restarts.filter { kept.contains($0.key) }
        for wait in waits where wait.isOpen { restarts[wait.id.uuidString, default: []].append(gap) }
        eventState.waitRestarts = restarts.isEmpty ? nil : restarts
        saveEventState()
        DaemonAliveFile.write(DaemonAlive(lastAlive: at), to: locations.alive)
        DaemonLog.shared.write("restart: \(gap.reason.rawValue), down for \(gap.downForWords)")
        return gap
    }

    /// `system.restarted`, once, after the waits are resumed, so a wait that names it is
    /// woken by it and a workflow on it runs.
    public func raiseRestarted() {
        guard let gap = lastRestart else { return }
        raise(EventDraft(name: "system.restarted", at: now(), scope: .mac,
                         sentence: EventWords.restartedSentence(gap), details: gap.details))
    }

    /// Say once a minute that the daemon is alive: one small file, overwritten.
    public func startSayingAlive(every interval: Duration = DaemonAlive.interval) {
        aliveTicker?.cancel()
        let file = locations.alive
        let clock = now
        aliveTicker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                DaemonAliveFile.write(DaemonAlive(lastAlive: clock()), to: file)
            }
        }
    }

    /// A clean stop: its time, so the next start says `stopped` rather than `crashed`.
    public func noteCleanStop() {
        aliveTicker?.cancel()
        aliveTicker = nil
        let at = now()
        DaemonAliveFile.write(DaemonAlive(lastAlive: at, stoppedAt: at), to: locations.alive)
    }

    /// What to add to a wait's wake or time-out: the restarts it was open over.
    func restartNotice(_ wait: EventWait) -> String {
        guard let gaps = eventState.waitRestarts?[wait.id.uuidString], !gaps.isEmpty else { return "" }
        return EventWords.restartNotice(gaps, wait: wait)
    }

    /// The details a change of state worked out again after a restart carries.
    static let noticedAfterRestart = ["noticed": "after_restart"]
}

/// `alive.json`, read and written off the actor's own state, so a signal handler can write
/// a stop without the daemon's actor (#1219).
public enum DaemonAliveFile {
    public static func read(_ file: URL) -> DaemonAlive? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? StoreCoding.decoder.decode(DaemonAlive.self, from: data)
    }

    public static func write(_ alive: DaemonAlive, to file: URL) {
        guard let data = try? StoreCoding.encoder.encode(alive) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// A stop now, written from anywhere: the daemon being told to go by a signal.
    public static func writeStopped(to file: URL) {
        let at = Date()
        write(DaemonAlive(lastAlive: at, stoppedAt: at), to: file)
    }
}
