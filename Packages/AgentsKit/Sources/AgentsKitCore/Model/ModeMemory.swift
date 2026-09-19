import Foundation

/// The mode a person keeps choosing, and whether it may still be used.
///
/// Two questions, both pure, both able to be wrong in ways somebody would notice:
/// which advertised option *is* the mode, and is a remembered value still one this
/// runtime offers. They live here rather than in the view so a test can reach them.
/// The storage does not — that is one `UserDefaults` key in the app, beside the
/// other things that are true of this Mac rather than of the work.
public enum ModeMemory {
    /// The option that is the mode, if the runtime advertises one.
    ///
    /// By `category == "mode"` first, because that is what the rest of the app keys
    /// on — `categoryOrder` puts it first, `isAboutPermission` reads it. By
    /// `id == "mode"` second, because that is what `SessionUpdate`'s mode change
    /// hard-codes. A switch is never the mode however it is labelled: there is
    /// nothing to remember about an on-or-off that its own value does not already say.
    public static func modeOption(in options: [ConfigOption]) -> ConfigOption? {
        let selectable = options.filter { if case .select = $0.kind { return true } else { return false } }
        return selectable.first { $0.category == "mode" } ?? selectable.first { $0.id == "mode" }
    }

    /// What the mode control should open on.
    ///
    /// The remembered value if the runtime still offers it; otherwise what the runtime
    /// says is current. A value a runtime has stopped offering is dropped without a
    /// word: it is not the person's mistake and there is nothing for them to do about
    /// it. Getting this wrong starts an agent in a mode nobody chose.
    public static func startingValue(remembered: JSONValue?, for option: ConfigOption) -> JSONValue? {
        guard let remembered, (option.options ?? []).contains(where: { $0.value == remembered }) else {
            return option.currentValue
        }
        return remembered
    }

    /// Where one runtime's remembered mode is kept.
    ///
    /// One key per runtime rather than one dictionary, matching `sidebar.isOpen` and
    /// its neighbours: a runtime never used leaves no entry, and an entry we cannot
    /// read costs that runtime rather than all of them.
    public static func defaultsKey(runtimeID: String) -> String { "prompt.mode.\(runtimeID)" }
}
