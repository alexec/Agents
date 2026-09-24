import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// What the machine says about its own power, read fresh every time.
///
/// The machine-side half of the wakefulness verdict. The agent-side half is
/// `DaemonCore.hasWorkInFlight`, and `Wake.verdict` is the only thing that sees both.
public struct PowerReading: Hashable, Sendable {
    /// Nil on a Mac with no battery — a desktop — which FR-012 treats as mains.
    ///
    /// Not zero, and not 100: those are both real readings a laptop can give, and a
    /// desktop is neither flat nor full. It has no battery, and the rule about
    /// batteries does not apply to it.
    public var batteryPercent: Int?
    public var isOnMains: Bool

    public init(batteryPercent: Int?, isOnMains: Bool) {
        // Clamped rather than trusted. A percentage is arithmetic on two numbers IOKit
        // gives us, and a max capacity of zero on a failing battery would otherwise
        // divide its way to something absurd and take the floor comparison with it.
        self.batteryPercent = batteryPercent.map { min(max($0, 0), 100) }
        self.isOnMains = isOnMains
    }
}

/// Where a `PowerReading` comes from.
///
/// A protocol so a test can cross the battery floor mid-turn without discharging a
/// laptop. It joins `SessionLauncher` and `Mailbox` as a seam on `DaemonCore.init`, for
/// the same reason those exist: the thing under test is the derivation, not the
/// machine.
public protocol PowerSource: Sendable {
    func read() -> PowerReading
}

/// The real one, read from IOKit.
///
/// Works from `agentsd`, which is the fact this whole design rests on: it is a non-GUI
/// helper with no AppKit and no run loop, and it can still read the power source and
/// hold a power assertion. Verified in a spike before this was planned — see
/// `specs/024-keep-host-awake/research.md` §3.
public struct IOKitPowerSource: PowerSource {
    public init() {}

    public func read() -> PowerReading {
        #if canImport(IOKit)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unknown }

        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let isOnMains = providing != kIOPSBatteryPowerValue

        // A Mac with no battery. `isOnMains` is already true above — nothing is
        // providing battery power — and this says so a second way, so the verdict does
        // not have to infer a desktop from the absence of a number.
        guard !sources.isEmpty else {
            return PowerReading(batteryPercent: nil, isOnMains: true)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }
            // Divided, never assumed. `kIOPSMaxCapacityKey` is not reliably 100 — on an
            // aged battery it is the capacity that battery still has, and reading
            // `current` as a percentage directly would quietly overstate the charge on
            // exactly the machines most likely to need the floor.
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerReading(batteryPercent: percent, isOnMains: isOnMains)
        }

        // Sources exist but none of them would answer. Not a desktop, and not a
        // reading either.
        return PowerReading(batteryPercent: nil, isOnMains: isOnMains)
        #else
        return .unknown
        #endif
    }
}

extension PowerReading {
    /// What to believe when the machine will not say.
    ///
    /// Mains, which means *hold*. This looks arbitrary and is not: the two ways of
    /// being wrong here are not equally bad. Holding wrongly leaves a Mac awake, which
    /// the person can see, and which `pmset -g assertions` will name us for. Releasing
    /// wrongly loses somebody's turn in the middle, silently, and they find out when
    /// they come back to a stopped agent and a half-finished edit.
    ///
    /// So the failure goes the visible way (024 T005).
    public static let unknown = PowerReading(batteryPercent: nil, isOnMains: true)
}
