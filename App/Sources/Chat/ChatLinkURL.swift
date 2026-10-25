import Foundation

/// Returns a file URL for a chat link that names a file on the session host.
enum ChatLinkURL {
    static func fileURL(from url: URL) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme == nil, url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: url.path)
    }
}
