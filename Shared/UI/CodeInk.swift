import CodeText
import SwiftUI

/// What code is printed in (041 research R4).
///
/// Nine roles, one colour each in light and dark, taken from the numbers in
/// `Packages/CodeText/Sources/CodeText/InkValues.swift`, where they are checked for contrast
/// against `Paper.ground` and `Paper.well` and for anything that reads as red. Red stays
/// `StateTint`'s, for something having gone wrong; code is never coloured to look like an
/// error, and a change is never coloured at all (035 FR-013).
///
/// Quiet on purpose: code sits in a well on paper, and the colours are inks rather than a
/// screen theme. Keywords carry weight as well as colour, and comments are set in italic, so
/// the two things read most often are told apart in grey-scale too.
enum CodeInk {
    /// The attributes a stretch of code takes, laid over the line's `TextStep.code` font.
    static func attributes(for role: CodeRole) -> AttributeContainer {
        var container = AttributeContainer()
        guard let color = colors[role] else { return container }
        container.foregroundColor = color
        switch role {
        case .keyword: container.font = TextStep.code.font.weight(.semibold)
        case .comment: container.font = TextStep.code.font.italic()
        default: break
        }
        return container
    }

    /// A removed line sits on this: a faint neutral wash, never a colour (035 FR-013).
    static let removedWash = Paper.ink.opacity(0.06)
    /// The words that changed within a changed line, on both sides: the same neutral,
    /// stronger, so the change is found before the line is read (041 FR-009).
    static let changedWash = Paper.ink.opacity(0.14)

    private static let colors: [CodeRole: Color] = Dictionary(uniqueKeysWithValues:
        CodeRole.allCases.compactMap { role in
            guard let light = InkValues.light[role], let dark = InkValues.dark[role] else {
                return nil
            }
            return (role, Color(light: light, dark: dark))
        })
}
