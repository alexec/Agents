import Foundation

/// How long archived agents are kept, and how much space they may take (051).
///
/// The person's, kept by the daemon. Forever with no limit is retirement turned off.
public struct RetentionSettings: Codable, Hashable, Sendable {
    public var keepFor: KeepFor
    public var cap: Cap

    public init(keepFor: KeepFor = .days30, cap: Cap = .gb2) {
        self.keepFor = keepFor
        self.cap = cap
    }

    /// Nothing is retired, however old or large.
    public var isOff: Bool { keepFor == .forever && cap == .none }

    public enum KeepFor: String, Codable, Hashable, Sendable, CaseIterable {
        case days7, days14, days30, days90, forever

        public var interval: TimeInterval? {
            switch self {
            case .days7: return 7 * 86_400
            case .days14: return 14 * 86_400
            case .days30: return 30 * 86_400
            case .days90: return 90 * 86_400
            case .forever: return nil
            }
        }

        /// A value a newer build wrote is the default, never Forever: a file this build
        /// cannot read must not turn retirement off on the person's behalf.
        public init(from decoder: any Decoder) throws {
            self = KeepFor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .days30
        }
    }

    public enum Cap: String, Codable, Hashable, Sendable, CaseIterable {
        case gb1, gb2, gb5, gb10, none

        /// In the gigabytes Finder shows, a thousand million bytes.
        public var bytes: Int? {
            switch self {
            case .gb1: return 1_000_000_000
            case .gb2: return 2_000_000_000
            case .gb5: return 5_000_000_000
            case .gb10: return 10_000_000_000
            case .none: return nil
            }
        }

        /// As `KeepFor`: never No limit by accident.
        public init(from decoder: any Decoder) throws {
            self = Cap(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .gb2
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepFor = (try? c.decode(KeepFor.self, forKey: .keepFor)) ?? .days30
        cap = (try? c.decode(Cap.self, forKey: .cap)) ?? .gb2
    }
}
