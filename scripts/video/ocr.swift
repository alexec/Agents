// Reads the text in pictures with Vision, for the token check (#1794, tokens.py). Each path
// on stdin, one a line; for each, one JSON line on stdout: {"path": …, "text": [every line it
// read, with each of its other readings]}. Accurate recognition, no language correction, so
// a token is read as letters and digits, not as words.
//
//   swiftc -O scripts/video/ocr.swift -o ~/.cache/agents-video/ocr   (tokens.py does this)
import Foundation
import Vision

func read(_ url: URL) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0
    let handler = VNImageRequestHandler(url: url)
    do {
        try handler.perform([request])
    } catch {
        FileHandle.standardError.write(Data("ocr: \(url.lastPathComponent) could not be read\n".utf8))
        return []
    }
    return (request.results ?? []).flatMap { line in line.topCandidates(3).map(\.string) }
}

while let line = readLine() {
    let path = line.trimmingCharacters(in: .whitespaces)
    if path.isEmpty { continue }
    let answer: [String: Any] = ["path": path, "text": read(URL(fileURLWithPath: path))]
    let data = try JSONSerialization.data(withJSONObject: answer)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
