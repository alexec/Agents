import Foundation
import Testing
@testable import AgentsKitCore

/// The runtime list crosses to phones built before and after 048, and from servers
/// built before it. Neither end may fail the whole list over a state it has not heard of.
@Suite("Runtime availability on the wire")
struct RuntimeAvailabilityCodingTests {
    @Test func everyCaseRoundTrips() throws {
        let all: [RuntimeAvailability] = [
            .available(path: "/bin/grok", supportsResume: true),
            .missing(lookedIn: ["/a", "/b"]),
            .needsSignIn(authMethods: ["x"], fixCommand: "grok login"),
            .needsSignIn(authMethods: [], fixCommand: nil),
            .failed(reason: "no"),
            .installing(progress: "Downloading"),
            .installing(progress: nil),
            .installFailed(reason: "nope"),
        ]
        for value in all {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(RuntimeAvailability.self, from: data) == value)
        }
    }

    @Test func theShapeIsWhatTheCompilerWroteBefore() throws {
        let data = try JSONEncoder().encode(RuntimeAvailability.available(path: "/p", supportsResume: false))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        #expect(object?["available"]?["path"] as? String == "/p")
        let old = Data(#"{"needsSignIn":{"authMethods":["a"],"fixCommand":"x login"}}"#.utf8)
        #expect(try JSONDecoder().decode(RuntimeAvailability.self, from: old)
                == .needsSignIn(authMethods: ["a"], fixCommand: "x login"))
    }

    @Test func aStateFromANewerDaemonIsAFailureNotAnError() throws {
        let newer = Data(#"{"beingRepaired":{"eta":3}}"#.utf8)
        guard case .failed(let reason) = try JSONDecoder().decode(RuntimeAvailability.self, from: newer) else {
            Issue.record("not a failure"); return
        }
        #expect(reason.contains("beingRepaired"))
    }

    /// A daemon from before 047/048 is past the cut-off (#58): its runtimes do not read.
    @Test func aRuntimeFromBeforeRecipesDoesNotRead() {
        let old = Data(#"{"id":"grok","name":"Grok","executable":"grok","arguments":["agent","stdio"]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Runtime.self, from: old) }
    }

    /// A way of installing a newer daemon invented costs the install, not the runtime.
    @Test func anInstallThisBuildDoesNotKnowIsNoInstall() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RuntimeCatalog.grok)) as! [String: Any]
        object["install"] = ["teleport": ["where": "space"]]
        let runtime = try JSONDecoder().decode(Runtime.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(runtime.install == nil)
        #expect(runtime.installPage == RuntimeCatalog.grok.installPage)
    }

    @Test func aRecipeRoundTrips() throws {
        for runtime in RuntimeCatalog.builtIn {
            let data = try JSONEncoder().encode(runtime)
            #expect(try JSONDecoder().decode(Runtime.self, from: data) == runtime)
        }
    }
}
