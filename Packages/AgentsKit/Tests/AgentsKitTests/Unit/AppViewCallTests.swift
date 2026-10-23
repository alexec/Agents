import Testing
@testable import AgentsKitCore

@Suite("App view tool results")
struct AppViewCallTests {
    @Test func structuredResultRemainsReadableWhenAViewCannotLoad() {
        let call = AppViewCall(tool: "get_me", resourceURI: "ui://github/profile",
                              result: .object(["structuredContent": .object(["login": .string("alexec")])]),
                              state: .done)
        #expect(call.resultText?.contains("\"login\":\"alexec\"") == true)
    }

    @Test func textResultKeepsItsOriginalForm() {
        let call = AppViewCall(tool: "get_me", resourceURI: "ui://github/profile",
                              result: .object(["content": .array([
                                .object(["type": .string("text"), "text": .string("alexec")])
                              ])]), state: .done)
        #expect(call.resultText == "alexec")
    }
}
