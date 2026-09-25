import Foundation

public enum CodeText {
    /// One line of code as styled text: each span's stretch takes `style(role)`, the rest
    /// takes `plain`, and any stretch inside one of `marks` (changed words, FR-009) takes
    /// `mark` on top of its colour. The characters are the line's, exactly and in order:
    /// styling is laid over the text and never changes it (FR-006).
    public static func attributed(
        _ line: Substring,
        spans: [CodeSpan],
        plain: AttributeContainer = AttributeContainer(),
        style: (CodeRole) -> AttributeContainer,
        marks: [Range<Int>] = [],
        mark: AttributeContainer = AttributeContainer()
    ) -> AttributedString {
        let utf16 = line.utf16
        let count = utf16.count
        guard count > 0 else { return AttributedString() }
        if spans.isEmpty, marks.isEmpty {
            return AttributedString(String(line), attributes: plain)
        }

        // Cut the line wherever a span or a mark starts or ends, then style each piece once.
        var cuts: Set<Int> = [0, count]
        for span in spans {
            cuts.insert(min(max(span.range.lowerBound, 0), count))
            cuts.insert(min(max(span.range.upperBound, 0), count))
        }
        for range in marks {
            cuts.insert(min(max(range.lowerBound, 0), count))
            cuts.insert(min(max(range.upperBound, 0), count))
        }
        let points = cuts.sorted()

        var result = AttributedString()
        for (from, to) in zip(points, points.dropFirst()) where from < to {
            let a = utf16.index(utf16.startIndex, offsetBy: from)
            let b = utf16.index(utf16.startIndex, offsetBy: to)
            var attributes = spans.last(where: { $0.range.contains(from) }).map { style($0.role) }
                ?? plain
            if marks.contains(where: { $0.contains(from) }) {
                attributes.merge(mark)
            }
            result.append(AttributedString(String(line[a..<b]), attributes: attributes))
        }
        return result
    }
}
