import SwiftUI

/// `Shared/UI/TypeScale.swift` as the phone resolves it, for drawing on a Mac.
///
/// The real file resolves each step to the Mac's own (smaller) text styles when built for
/// macOS, which would make every row look roomier than it is on a phone. These are the
/// iOS styles at the default text size — New York for the serif steps — times `scale`,
/// which the renderer raises to draw a larger Dynamic Type setting.
enum TextStep {
    case title, reading, supporting, fine, code

    nonisolated(unsafe) static var scale: CGFloat = 1

    var font: Font {
        let s = Self.scale
        switch self {
        case .title: return .system(size: 28 * s, design: .serif)
        case .reading: return .system(size: 17 * s, design: .serif)
        case .supporting: return .system(size: 15 * s, design: .serif)
        case .fine: return .system(size: 13 * s)
        case .code: return .system(size: 15 * s).monospaced()
        }
    }
}

extension View {
    func appText(_ step: TextStep) -> some View { font(step.font) }
}

/// SwiftUI's `Link`, which `ImageRenderer` draws as a placeholder, as just its label.
/// Declared in this module, it shadows SwiftUI's for the widget's own files.
struct Link<Label: View>: View {
    let destination: URL
    let label: Label

    init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    var body: some View { label }
}
