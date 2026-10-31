import Testing
@testable import AgentsKitCore

/// A persona's labels on the start form (#2649): only the picked one's are added, and the
/// person's own stay.
@Suite("A persona's labels")
struct PersonaLabelsTests {
    let reviewer = Persona(id: "reviewer", origin: .folder, settings: WorkflowSettings(labels: ["review", "Bugs"]))
    let engineer = Persona(id: "engineer", origin: .folder, settings: WorkflowSettings(labels: ["code", "bugs"]))

    @Test func pickingOneAddsItsLabelsBesideThoseThere() {
        #expect(Persona.labels(["bugs"], switchingFrom: nil, to: reviewer) == ["bugs", "review"])
    }

    @Test func switchingTakesTheLastOnesAwayKeepingThoseBothName() {
        #expect(Persona.labels(["mine", "review", "Bugs"], switchingFrom: reviewer, to: engineer)
                == ["mine", "Bugs", "code"])
    }

    @Test func noPersonaKeepsOnlyThePersonsOwn() {
        #expect(Persona.labels(["mine", "review", "Bugs"], switchingFrom: reviewer, to: nil) == ["mine"])
    }
}
