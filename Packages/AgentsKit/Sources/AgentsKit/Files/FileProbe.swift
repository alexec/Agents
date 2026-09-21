import Foundation

/// What the files pane learns about a file before it shows anything.
///
/// The pane reads a prefix, never the file. A 200MB log opens as fast as a small one
/// because the same number of bytes is read either way, which is FR-015. The size comes
/// from the file's attributes rather than from counting what was read.
public struct FileProbe: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        /// A picture, for the surface to draw rather than read. Decided from the name
        /// and not the bytes: an SVG passes every byte-level test for text and is
        /// still a picture, and a pane would rather draw it than number its lines. The
        /// description is carried for the day the drawing fails, so what is said then
        /// is the same thing that would be said of any other binary.
        case image(describedAs: String)
        /// What it is, said in words, because its bytes are not worth showing (FR-014).
        case binary(describedAs: String)

        public var isText: Bool { if case .text = self { return true }; return false }
    }

    /// How much is read to decide, and to show. Enough for a screenful of any file and
    /// small enough that a huge one costs nothing.
    public static let prefixLimit = 128 * 1024

    /// How much is looked at to decide text or binary. The whole prefix would do; this
    /// is the conventional window and it keeps the decision cheap.
    static let sniffLimit = 8 * 1024

    public let kind: Kind
    public let prefix: Data
    public let isTruncated: Bool
    public let size: Int

    public var text: String? {
        guard kind.isText else { return nil }
        return String(decoding: prefix, as: UTF8.self)
    }

    public init(kind: Kind, prefix: Data, isTruncated: Bool, size: Int) {
        self.kind = kind
        self.prefix = prefix
        self.isTruncated = isTruncated
        self.size = size
    }

    public enum Failure: Error, Equatable {
        case gone
        case notReadable
        case isDirectory
    }

    /// Read enough of a file to show its start, and decide what it is.
    public static func read(_ url: URL, limit: Int = prefixLimit) throws -> FileProbe {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true { throw Failure.isDirectory }
        guard let values, values.isRegularFile == true else { throw Failure.gone }
        let size = values.fileSize ?? 0

        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.notReadable }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: limit)) ?? Data()

        return FileProbe(kind: classify(prefix, filename: url.lastPathComponent, size: size),
                         prefix: prefix,
                         isTruncated: size > prefix.count,
                         size: size)
    }

    /// Text, image or neither, from the name and the first bytes.
    ///
    /// The name is asked first and only about images. Every image format the Mac can
    /// draw has a NUL in its first bytes, so the byte rules below would call them all
    /// binary, and the pane would describe a picture instead of showing it — which is
    /// what it did until someone asked to see the picture.
    ///
    /// A NUL byte means binary: no text encoding this app shows puts one in the middle
    /// of a document, and every binary format has them early. Invalid UTF-8 means
    /// binary too, which catches UTF-16 (its ASCII is NUL-padded anyway) and every
    /// compressed or compiled format.
    ///
    /// An empty file is text. There is nothing in it to be binary.
    public static func classify(_ prefix: Data, filename: String, size: Int) -> Kind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if imageKinds.contains(ext) { return .image(describedAs: describe(filename, size: size)) }

        let window = prefix.prefix(sniffLimit)
        if window.contains(0) { return .binary(describedAs: describe(filename, size: size)) }
        if window.isEmpty { return .text }

        // A prefix cut mid-character is not a reason to call a file binary, so the last
        // few bytes of a truncated read are allowed to be an incomplete sequence.
        if String(data: window, encoding: .utf8) == nil {
            let trimmed = withoutTrailingPartialCharacter(window)
            if String(data: trimmed, encoding: .utf8) == nil {
                return .binary(describedAs: describe(filename, size: size))
            }
        }
        return .text
    }

    /// The window without the character its cut left half of.
    ///
    /// Dropping a fixed three bytes is not enough. In a run of three-byte characters —
    /// box drawing, say — dropping three lands on another lead byte and the window is
    /// still invalid, so a perfectly good text file reads as binary. This walks back
    /// over continuation bytes to the character that was cut and drops from there.
    static func withoutTrailingPartialCharacter(_ window: Data) -> Data {
        var index = window.endIndex
        // At most four bytes to a character, so at most three continuations to walk.
        for _ in 0..<3 {
            guard index > window.startIndex else { return window }
            index = window.index(before: index)
            if window[index] & 0xC0 != 0x80 { return window[..<index] }
        }
        return window
    }

    /// What to say about a file instead of showing it.
    static func describe(_ filename: String, size: Int) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let kind = knownKinds[ext] ?? (ext.isEmpty ? "Binary file" : "\(ext.uppercased()) file")
        return "\(kind), \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    /// The formats AppKit decodes without help. Listed here rather than asked of the
    /// system because this half of the kit is also built for iOS, where there is no
    /// AppKit to ask; the surface finds out for itself when it draws, and a name on
    /// this list that turns out not to decode is handed back as a plain binary.
    static let imageKinds: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "icns",
    ]

    private static let knownKinds: [String: String] = [
        "png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF image",
        "heic": "HEIC image", "heif": "HEIF image", "webp": "WebP image", "tiff": "TIFF image",
        "tif": "TIFF image", "bmp": "BMP image", "svg": "SVG image", "icns": "Icon",
        "pdf": "PDF document", "zip": "Zip archive", "gz": "Gzip archive", "tar": "Tar archive",
        "mp3": "Audio", "wav": "Audio", "m4a": "Audio", "mp4": "Video", "mov": "Video",
        "o": "Object file", "a": "Static library", "dylib": "Dynamic library",
        "so": "Shared library", "class": "Java class", "wasm": "WebAssembly",
        "sqlite": "SQLite database", "db": "Database", "bin": "Binary file",
        "ttf": "Font", "otf": "Font", "woff": "Font", "woff2": "Font",
    ]
}
