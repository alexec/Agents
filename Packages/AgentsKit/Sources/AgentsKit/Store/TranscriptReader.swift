import Foundation

/// Reads a transcript by the line, without loading it whole.
///
/// One pass builds an index of where each line starts; after that a page is a seek and
/// a read. An agent that has been going for hours has a transcript in the tens of
/// megabytes, and the window only ever shows the end of it.
struct TranscriptReader {
    let url: URL

    init(url: URL) { self.url = url }

    /// Byte offsets of the start of every complete line.
    ///
    /// A trailing fragment with no newline is left out: that is a daemon that died
    /// mid-write, and half an entry is not an entry.
    private func lineOffsets() throws -> [UInt64] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offsets: [UInt64] = [0]
        var position: UInt64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            for (i, byte) in chunk.enumerated() where byte == 0x0A {
                offsets.append(position + UInt64(i) + 1)
            }
            position += UInt64(chunk.count)
        }
        // The final offset is either the end of the file or the start of a fragment
        // with no newline after it. Neither is the start of a complete line, and a
        // fragment is a daemon that died mid-write rather than an entry.
        offsets.removeLast()
        return offsets
    }

    var count: Int {
        get throws { try lineOffsets().count }
    }

    func page(before: Int?, limit: Int) throws -> TranscriptPage {
        let offsets = try lineOffsets()
        let total = offsets.count
        guard total > 0 else { return TranscriptPage(firstIndex: 0, total: 0, entries: []) }

        let end = min(before ?? total, total)
        let start = max(0, end - limit)
        guard start < end else { return TranscriptPage(firstIndex: start, total: total, entries: []) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offsets[start])
        let data: Data
        if end < total {
            data = try handle.read(upToCount: Int(offsets[end] - offsets[start])) ?? Data()
        } else {
            data = try handle.readToEnd() ?? Data()
        }

        var entries: [TranscriptEntry] = []
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
