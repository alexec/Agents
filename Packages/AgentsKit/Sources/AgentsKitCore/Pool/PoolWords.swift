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
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
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
        case .out(let until?, _, let why):
            return "Out until \(time(until, now: now))" + (why == .overage ? " · paid extra usage began" : "")
        case .out(nil, let retry?, _):
            return "Out since \(time(state.since, now: now)) · trying again after \(time(retry, now: now))"
        case .out(nil, nil, .creditExpired):
            return "Free credit expired"
        case .out(nil, nil, _):
            return "Credit used up"
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
        return "\(name)’s allowance ran out, until \(time(returnsAt, now: now))."
    }

    public static func overageBegan(_ runtimeID: String) -> String {
        "\(runtimeName(runtimeID)) started using paid extra usage, so it is treated as out."
    }

    public static func creditGone(_ runtimeID: String) -> String {
        "\(runtimeName(runtimeID))’s credit is used up."
    }

    public static func rateLimited(_ runtimeID: String, retryAt: Date, now: Date) -> String {
        "\(runtimeName(runtimeID)) is rate limited. Trying again at \(time(retryAt, now: now))."
    }

    public static func stillRateLimited(_ runtimeID: String) -> String {
        "\(runtimeName(runtimeID)) is still rate limited after retrying, so it is treated as out for an hour."
    }
}
