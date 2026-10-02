import Foundation

/// Reads a transcript by the line, without loading it whole.
///
/// An index of where each line starts is built once and then only grown: the daemon
/// is the file's only writer and only ever appends, so what was indexed last time is
/// still true and the scan picks up where it left off. After that a page is a seek
/// and a read. An agent that has been going for hours has a transcript in the tens of
/// megabytes, and the window only ever shows the end of it.
struct TranscriptReader {
    let url: URL

    init(url: URL) { self.url = url }

    /// Where every complete line starts, and how far the file was read to find out.
    ///
    /// A trailing fragment with no newline is not in it: that is a daemon that died
    /// mid-write, and half an entry is not an entry. `scanned` stays at the start of
    /// the fragment, so the newline that later ends it is found by the next scan.
    struct Index: Sendable {
        /// The byte after each newline, which is where the next line starts. The
        /// first line starts at zero and is not listed; `count` is the number of
        /// complete lines, one per newline found.
        var lineEnds: [UInt64] = []
        var scanned: UInt64 = 0

        var count: Int { lineEnds.count }

        /// Where line `index` starts.
        func start(of index: Int) -> UInt64 {
            index == 0 ? 0 : lineEnds[index - 1]
        }
    }

    /// Bring an index up to the end of the file.
    ///
    /// A file shorter than the index says was scanned is not the file the index was
    /// built for — somebody truncated or replaced it — and is read again from the top.
    func extend(_ index: inout Index) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            index = Index()
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < index.scanned { index = Index() }
        guard size > index.scanned else { return }

        try handle.seek(toOffset: index.scanned)
        var position = index.scanned
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard var cursor = bytes.baseAddress else { return }
                let end = cursor + bytes.count
                // `memchr` rather than a loop over the bytes: a byte at a time through
                // `Data` is the slow part of opening a long conversation.
                while cursor < end, let found = memchr(cursor, 0x0A, end - cursor) {
                    let next = UnsafeRawPointer(found) + 1
                    index.lineEnds.append(position + UInt64(next - bytes.baseAddress!))
                    cursor = next
                }
            }
            position += UInt64(chunk.count)
        }
        // Only up to the last newline. What follows it is a fragment until it is
        // ended, and it is scanned again then.
        index.scanned = index.lineEnds.last ?? 0
    }

    /// The lines from `from` on whose bytes hold `needle`, found without decoding any
    /// of them (#91). A line is read whole or not at all, so a needle with no newline in
    /// it is never cut in two.
    func lines(containing needle: String, _ index: Index, from: Int) throws -> [Int] {
        guard from < index.count else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let pattern = Array(needle.utf8)
        var found: [Int] = []
        var line = from
        while line < index.count {
            // About 4 MB at a time, ended at a line's end.
            let start = index.start(of: line)
            var last = line
            while last + 1 < index.count, index.lineEnds[last] - start < 4 << 20 { last += 1 }
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(index.lineEnds[last] - start)) ?? Data()
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var cursor = base
                let end = base + bytes.count
                var current = line
                while cursor < end, let hit = memmem(cursor, end - cursor, pattern, pattern.count) {
                    let at = start + UInt64(UnsafeRawPointer(hit) - base)
                    // The line it is on: the first whose end is past it.
                    while index.lineEnds[current] <= at { current += 1 }
                    found.append(current)
                    // On to the next line; one hit is enough to look at a line.
                    cursor = base + Int(index.lineEnds[current] - start)
                    current += 1
                }
            }
            line = last + 1
        }
        return found
    }

    /// The entries on lines `range`, one for each line, nil where a line will not
    /// decode, so a caller can count by the line rather than by what decoded.
    func entries(_ index: Index, lines range: Range<Int>) throws -> [TranscriptEntry?] {
        let range = range.clamped(to: 0..<index.count)
        guard !range.isEmpty else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let from = index.start(of: range.lowerBound)
        try handle.seek(toOffset: from)
        let data = try handle.read(upToCount: Int(index.lineEnds[range.upperBound - 1] - from)) ?? Data()
        var entries: [TranscriptEntry?] = []
        entries.reserveCapacity(range.count)
        var cursor = data.startIndex
        for line in range {
            let end = data.startIndex + Int(index.lineEnds[line] - from) - 1
            entries.append(try? StoreCoding.decoder.decode(TranscriptEntry.self, from: data[cursor..<end]))
            cursor = end + 1
        }
        return entries
    }

    /// A page out of an index that is already up to date.
    func page(_ index: Index, before: Int?, limit: Int) throws -> TranscriptPage {
        let total = index.count
        guard total > 0 else { return TranscriptPage(firstIndex: 0, total: 0, entries: []) }

        let end = min(before ?? total, total)
        let start = max(0, end - limit)
        guard start < end else { return TranscriptPage(firstIndex: start, total: total, entries: []) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let from = index.start(of: start)
        try handle.seek(toOffset: from)
        let data = try handle.read(upToCount: Int(index.lineEnds[end - 1] - from)) ?? Data()

        var entries: [TranscriptEntry] = []
        entries.reserveCapacity(end - start)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            // A line that will not decode is skipped, not fatal: the record is more
            // use with a gap in it than not at all.
            if let entry = try? StoreCoding.decoder.decode(TranscriptEntry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        return TranscriptPage(firstIndex: start, total: total, entries: entries)
    }
}
