import Testing
@testable import AgentsKitCore

/// Auto on the start form (#4559): the persona the first prompt's words name. Held to the
/// same cases as the web's `autoPersona` (`Web/test/personas.test.mjs`).
@Suite("Auto picks a persona")
struct PersonaAutoPickTests {
    let owner = Persona(id: "product-owner", name: "Product Owner", origin: .folder,
                        keywords: ["what about", "idea", "should we", "file an issue"])
    let master = Persona(id: "scrum-master", name: "Scrum Master", origin: .folder,
                         keywords: ["lanes", "land", "PRs", "merge"])
    let engineer = Persona(id: "software-engineer", name: "Software Engineer", origin: .folder,
                           keywords: ["fix", "build", "implement", Persona.issueNumberKeyword])
    var all: [Persona] { [owner, master, engineer] }

    @Test func aWholeKeywordPicksItsPersona() {
        let pick = Persona.autoPick("What about a dark mode?", among: all)
        #expect(pick?.persona.id == "product-owner")
        #expect(pick?.word == "what about")
    }

    @Test func aHalfTypedWordPicksNothing() {
        #expect(Persona.autoPick("fi", among: all) == nil)
        #expect(Persona.autoPick("fix", among: all) == nil)
        #expect(Persona.autoPick("fix ", among: all)?.persona.id == "software-engineer")
        #expect(Persona.autoPick("fixing it ", among: all) == nil)
    }

    @Test func caseDoesNotMatterAndTheFilesWordIsShown() {
        let pick = Persona.autoPick("land the prs, then stop", among: all)
        #expect(pick?.persona.id == "scrum-master")
        #expect(pick?.word == "land")
    }

    @Test func mostMatchesWins() {
        #expect(Persona.autoPick("An idea: merge the PRs and land them.", among: all)?.persona.id == "scrum-master")
    }

    @Test func theEarliestMatchBreaksATie() {
        let pick = Persona.autoPick("What about an issue for the lanes ", among: all)
        #expect(pick?.persona.id == "product-owner")
    }

    @Test func anIssueNumberIsAWord() {
        let pick = Persona.autoPick("Take #4559.", among: all)
        #expect(pick?.persona.id == "software-engineer")
        #expect(pick?.word == "#4559")
        #expect(Persona.autoPick("Take #4559", among: all) == nil)
        #expect(Persona.autoPick("Take a#1 ", among: all) == nil)
    }

    @Test func noMatchIsNoPersona() {
        #expect(Persona.autoPick("Tell me a joke.", among: all) == nil)
        #expect(Persona.autoPick("", among: all) == nil)
    }

    @Test func aBrokenPersonaIsNeverPicked() {
        var broken = engineer
        broken.problem = "The metadata could not be read"
        #expect(Persona.autoPick("fix it", among: [broken]) == nil)
    }

    @Test func withNoKeywordsItsNameAndDescriptionAreTheWords() {
        let reviewer = Persona(id: "reviewer", name: "Reviewer", description: "Reads every change for security bugs.",
                               origin: .folder)
        #expect(reviewer.autoWords == ["Reviewer", "Reads", "change", "security"])
        #expect(Persona.autoPick("A security check, please", among: [reviewer])?.word == "security")
    }
}
