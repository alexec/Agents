import Foundation

/// What a file was when it was read: enough to say, the next time, whether reading it
/// again would show anything new.
///
/// Coarse on purpose. A write that keeps both the size and the modification date is
/// read again on the next folder event, which is a cost of one read, not a wrong page.
public struct FileStamp: Codable, Sendable, Hashable {
    public var size: Int
    public var modifiedAt: Date

    public init(size: Int, modifiedAt: Date) {
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// A file as the daemon read it for a device (034 `files/read`).
///
/// The Mac's panes read the disk themselves. A phone has no disk to read, so this is the
/// file carried to it: its text, its picture, or a sentence saying what it is. "Gone"
/// and "not readable" are errors on the request, never cases here, so no client can
/// mistake a missing file for an empty one.
public enum FileReading: Sendable, Equatable {
    /// At most `FileProbe.prefixLimit` of it. `isTruncated` says there was more.
    case text(String, isTruncated: Bool, size: Int, stamp: FileStamp)
    /// The whole file, at most `imageLimit` of it.
    case image(Data, describedAs: String, stamp: FileStamp)
    /// Neither text nor a picture that can be carried: said, not shown.
    case other(describedAs: String, size: Int, stamp: FileStamp)
    /// The file still has the stamp the request named. Nothing is sent again.
    case unchanged(FileStamp)

    /// The largest picture sent whole. A photo straight off a camera is what this
    /// catches: one line of several megabytes holds every other notification on the
    /// connection behind it for as long as a slow link takes to carry it.
    public static let imageLimit = 4 * 1024 * 1024

    public var stamp: FileStamp {
        switch self {
        case .text(_, _, _, let stamp), .image(_, _, let stamp), .other(_, _, let stamp): stamp
        case .unchanged(let stamp): stamp
        }
    }

    /// Said above a text file that was cut: "Showing the first 128 KB of 3.2 MB."
    public static func truncationNote(shown: Int, of size: Int) -> String {
        let format = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        return "Showing the first \(format(shown)) of \(format(size))."
    }
}

extension FileReading: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, isTruncated, size, stamp, bytes, describedAs
    }

    private enum Kind: String, Codable {
        case text, image, other, unchanged
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stamp = try c.decode(FileStamp.self, forKey: .stamp)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text),
                         isTruncated: try c.decode(Bool.self, forKey: .isTruncated),
                         size: try c.decode(Int.self, forKey: .size),
                         stamp: stamp)
        case .image:
            self = .image(try c.decode(Data.self, forKey: .bytes),
                          describedAs: try c.decode(String.self, forKey: .describedAs),
                          stamp: stamp)
        case .other:
            self = .other(describedAs: try c.decode(String.self, forKey: .describedAs),
                          size: try c.decode(Int.self, forKey: .size),
                          stamp: stamp)
        case .unchanged:
            self = .unchanged(stamp)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stamp, forKey: .stamp)
        switch self {
        case .text(let text, let isTruncated, let size, _):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(isTruncated, forKey: .isTruncated)
            try c.encode(size, forKey: .size)
        case .image(let bytes, let describedAs, _):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(describedAs, forKey: .describedAs)
        case .other(let describedAs, let size, _):
            try c.encode(Kind.other, forKey: .kind)
            try c.encode(describedAs, forKey: .describedAs)
            try c.encode(size, forKey: .size)
        case .unchanged:
            try c.encode(Kind.unchanged, forKey: .kind)
        }
    }
}
