import Foundation
import Testing
@testable import AgentsKitCore

/// Add a Machine… and Where agents run (#2131): the name it takes, the slot's words, and New
/// Machine's request with no repository. The web page's addMachine.test.mjs is the same.
@Suite("Add a Machine")
struct AddMachineTests {
    @Test func aNameIsLettersDigitsAndDashes() {
        #expect(AddMachine.validName("build-2"))
        #expect(AddMachine.validName(" devbox "))
        #expect(!AddMachine.validName("2-build"))
        #expect(!AddMachine.validName("build 2"))
        #expect(!AddMachine.validName(""))
        #expect(!AddMachine.validName(String(repeating: "b", count: 64)))
    }

    @Test func whereAgentsRunSaysWhatElseIsYours() {
        #expect(WhereAgentsRun.line(others: [], providers: []) == "Agents run where this folder is.")
        #expect(WhereAgentsRun.line(others: ["devbox", "build-2"], providers: ["Docker"])
            == "Agents run where this folder is. Your other machines: devbox, build-2. Providers: Docker.")
        #expect(WhereAgentsRun.title(onThisMac: true, hostName: "alex-mbp") == "This Mac")
        #expect(WhereAgentsRun.title(onThisMac: false, hostName: "devbox") == "devbox")
    }

    @Test func aNewMachineWithNoRepositorySendsNone() {
        let field = MachineFromRepository.Field(key: "size", title: "Size", kind: .string, choices: nil, value: "s-1vcpu", help: nil)
        let request = MachineFromRepository.request(ProviderID(rawValue: "p1"), name: "build-2", repository: nil, fields: [field])
        #expect(request.repository == nil)
        #expect(request.options == .object(["size": .string("s-1vcpu")]))
    }
}
