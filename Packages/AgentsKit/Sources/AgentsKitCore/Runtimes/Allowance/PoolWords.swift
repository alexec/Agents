import Foundation

/// Every sentence the pool shows, in one place, so the Mac and the phone say the same
/// thing about the same allowance (052).
public enum PoolWords {
    public static func runtimeName(_ runtimeID: String) -> String {
        RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
    }

    /// "07:00" today, "Tue 07:00" within the week, a date after that. In the person's
    /// own time zone.
    public static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        // The person's own clock: 24-hour or with AM/PM, as the Mac is set.
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if date.timeIntervalSince(now) < 6 * 86400 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The state line on the Pool page (US3).
    public static func state(_ state: AllowanceState, now: Date) -> String {
        switch state.current(now: now) {
        case .available:
            return "Available"
        case .rateLimited(let until):
            return "Rate limited · trying again at \(time(until, now: now))"
        case .out(let until?, let retry?, let why):
            return "Out · reset \(time(until, now: now)) · checking after \(time(retry, now: now))"
                + (why == .overage ? " · paid extra usage began" : "")
        case .out(let until?, nil, let why):
            return "Out · reset \(time(until, now: now))"
                + (why == .overage ? " · paid extra usage began" : "")
        case .out(nil, let retry?, .creditUsedUp):
            return "Credit used up · checking after \(time(retry, now: now))"
        case .out(nil, let retry?, _):
            return "Out since \(time(state.since, now: now)) · checking after \(time(retry, now: now))"
        case .out(nil, nil, .creditExpired):
            return "Free credit expired"
        case .out(nil, nil, _):
            return "Credit used up"
        }
    }

    /// The models a provider failed on, while the runtime works (#140): "Model
    /// ling-3.0-flash out since 09:05 · checking after 13:05". Nil when none is out.
    public static func modelsOut(_ state: AllowanceState, now: Date) -> String? {
        let marks = state.modelsOut(now: now)
        guard !marks.isEmpty else { return nil }
        return marks.map {
            "Model \($0.name ?? $0.model) out since \(time($0.since, now: now)) · checking after \(time($0.retryAfter, now: now))"
        }.joined(separator: " · ")
    }

    /// The state line with any models out after it: the Pool page's line for a runtime.
    public static func stateWithModels(_ state: AllowanceState, now: Date) -> String {
        [Self.state(state, now: now), modelsOut(state, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the runtime last said is left of its plan window: "28% left this week ·
    /// resets Sun 20:39 · as of 14:02". Nil when there is no reading, or its window has
    /// reset since, when it would say nothing true about the new one.
    public static func reading(_ reading: AllowanceReading?, now: Date) -> String? {
        guard let reading, reading.isCurrent(now: now) else { return nil }
        let amount: String? = if let left = reading.left {
            left <= 0 ? "None left" : "\(Int((left * 100).rounded()))% left"
        } else if reading.nearlySpent {
            "Nearly used up"
        } else {
            nil
        }
        let window = windowName(reading.window)
        var parts: [String] = []
        switch (amount, window) {
        case (let amount?, let window?): parts.append("\(amount) \(window)")
        case (let amount?, nil): parts.append(amount)
        case (nil, let window?): parts.append(window.prefix(1).uppercased() + window.dropFirst())
        case (nil, nil): break
        }
        if let resetsAt = reading.resetsAt { parts.append("resets \(time(resetsAt, now: now))") }
        guard !parts.isEmpty else { return nil }
        parts.append("as of \(time(reading.at, now: now))")
        return parts.joined(separator: " · ")
    }

    /// "this week", "of the 5-hour window": a window's name as it follows an amount.
    private static func windowName(_ window: String?) -> String? {
        switch window {
        case nil: nil
        case "five_hour": "of the 5-hour window"
        case "seven_day", "weekly": "this week"
        case "seven_day_opus": "of the weekly Opus limit"
        case "seven_day_sonnet": "of the weekly Sonnet limit"
        case "monthly": "this month"
        case let other?: "of the \(other.replacingOccurrences(of: "_", with: " ")) window"
        }
    }

    /// The capsule beside an entry's name (FR-001a).
    public static func payment(_ payment: Payment, spent: AllowanceState.Spent? = nil) -> String {
        switch payment {
        case .allowance(let label?): return "Allowance · \(label)"
        case .allowance(nil): return "Allowance"
        case .freeTier(.dailyAt): return "Free tier · resets daily"
        case .freeTier: return "Free tier"
        case .freeCredit(let amount, _): return "Free credit" + used(spent, of: amount)
        case .prepaid(let amount, _): return "Prepaid credit" + used(spent, of: amount)
        }
    }

    private static func used(_ spent: AllowanceState.Spent?, of amount: Cost?) -> String {
        switch spent {
        case .unknown?: return " · spending not known"
        case .known(let cost?)?:
            let figure = cost.amount.formatted(.currency(code: cost.currency))
            guard let amount else { return " · ≈ \(figure) used" }
            return " · ≈ \(figure) of \(amount.amount.formatted(.currency(code: amount.currency))) used"
        default:
            return amount.map { " · \($0.amount.formatted(.currency(code: $0.currency)))" } ?? ""
        }
    }

    /// The chat's note when an allowance ran out and the chat stayed (slice 2) or moved.
    public static func ranOut(_ runtimeID: String, returnsAt: Date?, now: Date) -> String {
        let name = runtimeName(runtimeID)
        guard let returnsAt else { return "\(name)’s allowance ran out." }
        return "\(name)’s allowance ran out. Its provider says it resets at \(time(returnsAt, now: now)); the app checks before using it again."
    }

    /// The same, from its state: "until" only for a time the provider gave, and the
    /// app's own retry said as what it is.
    public static func ranOut(_ runtimeID: String, state: AllowanceState, now: Date) -> String {
        if let back = state.knownReturn { return ranOut(runtimeID, returnsAt: back, now: now) }
        if case .out(nil, let retry?, _) = state.status {
            return "\(runtimeName(runtimeID))’s allowance ran out. It is tried again after \(time(retry, now: now))."
        }
        return ranOut(runtimeID, returnsAt: nil, now: now)
    }

    public static func creditGone(_ runtimeID: String) -> String {
        "\(runtimeName(runtimeID))’s credit is used up."
    }

    public static func rateLimited(_ runtimeID: String, retryAt: Date, now: Date) -> String {
        "\(runtimeName(runtimeID)) is rate limited. Trying again at \(time(retryAt, now: now))."
    }

    /// Above a new chat's prompt, when its runtime is out (US3).
    public static func startingOnOut(_ runtimeID: String, state: AllowanceState, now: Date) -> String {
        let name = runtimeName(runtimeID)
        switch state.current(now: now) {
        case .out(let until?, _, _):
            return "\(name) is out. Its provider says it resets at \(time(until, now: now)); the app checks before using it again."
        case .out(nil, let retry?, _):
            // Not a time the provider gave: only when the app checks it again. Sending is
            // still the person's to do (065): a turn that works brings it back.
            return "\(name) is out. The app checks it again at \(time(retry, now: now))."
        default:
            return "\(name) is out."
        }
    }
}
