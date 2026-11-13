import Foundation

/// The images of one message or page that the image viewer goes through (#4954): in their order,
/// without the small ones and the ones that are links. `pageImage.ts` has the same rules for the
/// web page.
public enum ImageSequence {
    /// The least an image's longer side is, in points, to open large and be in the sequence. A
    /// logo, a badge or an icon is smaller, and stays as it is in the text.
    public static let least = 200.0

    /// Whether an image of this size opens large and is in the sequence.
    public static func opensLarge(width: Double, height: Double) -> Bool {
        max(width, height) >= least
    }

    /// The image after (`by` 1) or before (`by` -1) the one at `index`, or nil at an end.
    public static func step(from index: Int, count: Int, by: Int) -> Int? {
        let next = index + by
        return (0..<count).contains(next) && (0..<count).contains(index) ? next : nil
    }

    /// "2 of 5", or nil when there is only the one image.
    public static func counter(_ index: Int, of count: Int) -> String? {
        count > 1 ? "\(index + 1) of \(count)" : nil
    }

    /// The sources of the images in `blocks`, in their order, each once. An image that is a link
    /// is not an image block at all: Foundation reads it as the link's words, whose click follows it.
    public static func sources(in blocks: [MarkdownBlock]) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .image(let source, _):
                    if seen.insert(source).inserted { found.append(source) }
                case .list(_, _, let items):
                    for item in items { walk(item.blocks) }
                case .quote(let inner):
                    walk(inner)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return found
    }
}
