import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AgentsKitCore

/// What a paste into the prompt attaches, item by item (#396).
@Suite("Prompt paste")
struct PromptPasteTests {
    @Test func everyPictureThePaperclipTakesAttaches() {
        for type in [UTType.png, .jpeg, .gif, .heic, .webP, .tiff] {
            #expect(PromptPaste.kind(of: [type.identifier]) == .picture(type))
        }
    }

    @Test func aPictureOfAnotherKindStillAttaches() {
        #expect(PromptPaste.kind(of: [UTType.bmp.identifier]) == .picture(.bmp))
    }

    @Test func theMostSpecificKnownPictureIsTaken() {
        // A copied picture often comes as TIFF beside its own PNG.
        #expect(PromptPaste.kind(of: [UTType.tiff.identifier, UTType.png.identifier]) == .picture(.png))
    }

    @Test func aFileCopiedInFinderIsTheFileNotItsIcon() {
        let finder = [UTType.fileURL.identifier, UTType.utf8PlainText.identifier, UTType.tiff.identifier]
        #expect(PromptPaste.kind(of: finder) == .file)
    }

    @Test func wordsWithAPictureOfThemselvesAreWords() {
        let document = [UTType.rtf.identifier, UTType.utf8PlainText.identifier, UTType.png.identifier, UTType.pdf.identifier]
        #expect(PromptPaste.kind(of: document) == .words)
    }

    @Test func anythingElseIsNothingToAttach() {
        #expect(PromptPaste.kind(of: [UTType.pdf.identifier]) == .nothing)
        #expect(PromptPaste.kind(of: ["com.example.unknown"]) == .nothing)
        #expect(PromptPaste.kind(of: []) == .nothing)
    }

    @Test func aPictureGoesAsItsOwnMIMEType() {
        #expect(PromptPaste.mimeType(for: .png) == "image/png")
        #expect(PromptPaste.mimeType(for: .jpeg) == "image/jpeg")
        #expect(PromptPaste.mimeType(for: .heic) == "image/heic")
    }
}
