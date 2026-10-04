import Foundation

/// The app's look, as the CSS variables MCP Apps standardises (#187), so a view drawn in a
/// conversation is on the same paper as the conversation.
///
/// Every colour is a `light-dark()` pair: the light half is Paper's light value and the
/// dark half its dark one (`Shared/UI/Paper.swift`, `StateTint.swift`, the accent asset,
/// and `Web/src/theme/paper.css`, which say the same), and the view picks the half by its
/// `color-scheme`, which follows `hostContext.theme`. So System, Light and Dark come down
/// to `theme`, and Paper is the palette both halves are drawn from. The fonts are the
/// system's own, as on the web page: nothing is loaded from anywhere.
public enum AppViewTheme {
    public static let variables: [String: String] = {
        func pair(_ light: String, _ dark: String) -> String { "light-dark(\(light), \(dark))" }
        let ground = ("#fbf9f4", "#1c1b19"), raised = ("#ffffff", "#262421"), well = ("#f1ede4", "#2a2825")
        let wash = ("#ece7db", "#2f2c28"), rule = ("#e2dccf", "#3a3733"), ink = ("#1f1d1a", "#ece7dc")
        let accent = ("#5b3be0", "#ab8eff"), danger = ("#b42318", "#f07b6e")
        let success = ("#3b7a4a", "#7fbf8e"), warning = ("#c2410c", "#f08a4b")
        let secondaryInk = ("rgb(31 29 26 / 66%)", "rgb(236 231 220 / 66%)")
        let tertiaryInk = ("rgb(31 29 26 / 45%)", "rgb(236 231 220 / 45%)")
        let tint = { (colour: (String, String), percent: Int) in
            pair("color-mix(in srgb, \(colour.0) \(percent)%, \(ground.0))",
                 "color-mix(in srgb, \(colour.1) \(percent)%, \(ground.1))")
        }
        var out: [String: String] = [
            "--color-background-primary": pair(ground.0, ground.1),
            "--color-background-secondary": pair(raised.0, raised.1),
            "--color-background-tertiary": pair(well.0, well.1),
            "--color-background-inverse": pair(ink.0, ink.1),
            "--color-background-ghost": pair(wash.0, wash.1),
            "--color-background-info": tint(accent, 14),
            "--color-background-danger": tint(danger, 14),
            "--color-background-success": tint(success, 14),
            "--color-background-warning": tint(warning, 14),
            "--color-background-disabled": pair(wash.0, wash.1),
            "--color-text-primary": pair(ink.0, ink.1),
            "--color-text-secondary": pair(secondaryInk.0, secondaryInk.1),
            "--color-text-tertiary": pair(tertiaryInk.0, tertiaryInk.1),
            "--color-text-inverse": pair(ground.0, ground.1),
            "--color-text-info": pair(accent.0, accent.1),
            "--color-text-danger": pair(danger.0, danger.1),
            "--color-text-success": pair(success.0, success.1),
            "--color-text-warning": pair(warning.0, warning.1),
            "--color-text-disabled": pair(tertiaryInk.0, tertiaryInk.1),
            "--color-text-ghost": pair(tertiaryInk.0, tertiaryInk.1),
            "--color-border-primary": pair(rule.0, rule.1),
            "--color-border-secondary": pair(rule.0, rule.1),
            "--color-border-tertiary": pair(wash.0, wash.1),
            "--color-border-inverse": pair(ink.0, ink.1),
            "--color-border-ghost": pair(wash.0, wash.1),
            "--color-border-info": pair(accent.0, accent.1),
            "--color-border-danger": pair(danger.0, danger.1),
            "--color-border-success": pair(success.0, success.1),
            "--color-border-warning": pair(warning.0, warning.1),
            "--color-border-disabled": pair(rule.0, rule.1),
            "--color-ring-primary": pair(accent.0, accent.1),
            "--color-ring-secondary": pair(rule.0, rule.1),
            "--color-ring-inverse": pair(ground.0, ground.1),
            "--color-ring-info": pair(accent.0, accent.1),
            "--color-ring-danger": pair(danger.0, danger.1),
            "--color-ring-success": pair(success.0, success.1),
            "--color-ring-warning": pair(warning.0, warning.1),
            "--font-sans": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
            "--font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
            "--font-weight-normal": "400",
            "--font-weight-medium": "500",
            "--font-weight-semibold": "600",
            "--font-weight-bold": "700",
            "--border-radius-xs": "4px",
            "--border-radius-sm": "7px",
            "--border-radius-md": "10px",
            "--border-radius-lg": "16px",
            "--border-radius-xl": "20px",
            "--border-radius-full": "9999px",
            "--border-width-regular": "1px",
            "--shadow-hairline": "0 0 0 1px \(pair(rule.0, rule.1))",
            "--shadow-sm": "0 1px 2px rgb(59 47 30 / 10%)",
            "--shadow-md": "0 2px 6px rgb(59 47 30 / 10%)",
            "--shadow-lg": "0 6px 16px rgb(59 47 30 / 12%)",
        ]
        // Text and headings, on the system's own steps.
        let text: [(String, Int, Int)] = [("xs", 11, 14), ("sm", 12, 16), ("md", 14, 20), ("lg", 16, 24)]
        for (name, size, line) in text {
            out["--font-text-\(name)-size"] = "\(size)px"
            out["--font-text-\(name)-line-height"] = "\(line)px"
        }
        let headings: [(String, Int, Int)] = [("xs", 12, 16), ("sm", 14, 20), ("md", 16, 22), ("lg", 20, 26),
                                              ("xl", 24, 30), ("2xl", 28, 34), ("3xl", 34, 40)]
        for (name, size, line) in headings {
            out["--font-heading-\(name)-size"] = "\(size)px"
            out["--font-heading-\(name)-line-height"] = "\(line)px"
        }
        return out
    }()
}
