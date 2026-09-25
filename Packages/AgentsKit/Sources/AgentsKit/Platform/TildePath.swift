import Foundation

/// `~/src/api` for `/home/alex/src/api`, on both platforms (037). Apple's Foundation
/// has `abbreviatingWithTildeInPath`; the Linux one does not.
func abbreviatingHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
    guard !trimmedHome.isEmpty else { return path }
    if path == trimmedHome { return "~" }
    if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
    return path
}
