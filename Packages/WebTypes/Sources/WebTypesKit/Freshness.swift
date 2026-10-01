/// What to say when the checked-in generated.ts is not what the generator makes now.
public enum Freshness {
    public static func message(current: String?, made: String) -> String {
        guard let current else { return "\(Generator.output) is missing; run scripts/web.sh types" }
        let old = current.split(separator: "\n", omittingEmptySubsequences: false)
        let new = made.split(separator: "\n", omittingEmptySubsequences: false)
        let line = zip(old, new).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(old.count, new.count)
        let was = line < old.count ? String(old[line]) : "(end of file)"
        let now = line < new.count ? String(new[line]) : "(end of file)"
        return "\(Generator.output) is stale; run scripts/web.sh types\n  line \(line + 1) is:    \(was)\n  and should be: \(now)"
    }
}
