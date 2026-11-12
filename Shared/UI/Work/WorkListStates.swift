import AgentsKitCore
import SwiftUI

/// A Work list's empty, loading and error states (#4391, parts.md section 7).

/// The first read: placeholder rows, a grey circle and two grey bars each, with no spinner in the middle.
struct WorkPlaceholderRows: View {
    var count = WorkLook.placeholderRows

    var body: some View {
        ForEach(0 ..< count, id: \.self) { i in
            HStack(alignment: .top, spacing: 8) {
                Circle().frame(width: 14, height: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).frame(height: 11).frame(maxWidth: i.isMultiple(of: 2) ? 360 : 280)
                    RoundedRectangle(cornerRadius: 3).frame(width: 180, height: 9)
                }
            }
            .foregroundStyle(Paper.wash)
            .padding(.vertical, 5)
            .redacted(reason: .placeholder)
            .modifier(WorkShimmer())
            .accessibilityHidden(true)
        }
    }
}

/// A slow shimmer over the placeholders.
struct WorkShimmer: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// An empty list in the middle: the page's glyph, the title ("No open issues"), one line under
/// it, and the buttons where there are any (Clear filters; Try again and Settings ▸ Connectors).
struct WorkEmptyState: View {
    let symbol: String
    let title: String
    var line: String?
    var action: (title: String, run: () -> Void)?
    /// A second button beside it (Settings ▸ Connectors, for a credential the forge refused).
    var also: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(icon: symbol)
                // The empty state's own glyph, larger than any text step: a marked decorative glyph.
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).appText(.reading).fontWeight(.semibold)
            if let line {
                Text(line).appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                if let action { Button(action.title, action: action.run).buttonStyle(.paper) }
                if let also { Button(also.title, action: also.run).buttonStyle(.paper) }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the forges said when a read failed: a strip above the list (not in place of it), a
/// failure banner (#4737), the forge's words, one line each, and Try again.
struct WorkErrorStrip: View {
    let lines: [String]
    var retry: (() -> Void)?

    var body: some View {
        // A failure banner (#4737): a read that failed. Not the `forge.waiting` wash, which is
        // for a check that runs.
        if !lines.isEmpty {
            PaneBanner(tone: .failure, announcement: lines.joined(separator: " ")) {
                ForEach(lines, id: \.self) { Text($0).lineLimit(1).truncationMode(.tail).help($0) }
            } actions: {
                if let retry {
                    Button(WorkLook.tryAgain, action: retry)
                }
            }
        }
    }
}
