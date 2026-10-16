import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A banner's own buttons (#1170): made from the question's options, only where one tap
/// or one line is a whole answer, and sent as the card's answer.
@Suite("Quick answers on a banner", .timeLimit(.minutes(2)))
struct QuickAnswerTests {
    private let agentID = UUID()

    private func permission(_ options: [PermissionOption]) -> PermissionRequest {
        PermissionRequest(agentID: agentID, toolCall: ToolCall(toolCallID: "c1", title: "rm -rf build"), options: options)
    }

    private func form(_ properties: [ElicitationSchema.Property]) -> ElicitationRequest {
        ElicitationRequest(agentID: agentID, message: "Which?", mode: .form(ElicitationSchema(properties: properties)))
    }

    private func choice(_ name: String, _ values: [String], required: Bool = true) -> ElicitationSchema.Property {
        .init(name: name, isRequired: required,
              kind: .string(format: nil, minLength: nil, maxLength: nil,
                            choices: values.map { .init(value: $0, title: $0.capitalized) }))
    }

    private func text(_ name: String, required: Bool = true) -> ElicitationSchema.Property {
        .init(name: name, isRequired: required, kind: .string(format: nil, minLength: nil, maxLength: nil, choices: nil))
    }

    @Test func aPermissionHasItsOwnOptionsInOrder() throws {
        let answers = try #require(QuickAnswer.answers(for: permission([
            .init(optionID: "once", name: "Allow once", kind: .allowOnce),
            .init(optionID: "always", name: "Always allow", kind: .allowAlways),
            .init(optionID: "no", name: "Reject", kind: .rejectOnce),
        ])))
        #expect(answers.map(\.id) == ["once", "always", "no"])
        #expect(answers.map(\.title) == ["Allow once", "Always allow", "Reject"])
        #expect(answers.map(\.isDestructive) == [false, false, true])
        #expect(answers.allSatisfy { $0.kind == .choice && $0.field == nil })
    }

    @Test func aPermissionWithNoOptionsOrTooManyHasNone() {
        #expect(QuickAnswer.answers(for: permission([])) == nil)
        let five = (0..<5).map { PermissionOption(optionID: "\($0)", name: "\($0)", kind: .allowOnce) }
        #expect(QuickAnswer.answers(for: permission(five)) == nil)
    }

    @Test func oneChoiceOfTwoToFourIsAButtonEach() throws {
        let answers = try #require(QuickAnswer.answers(for: form([choice("q", ["red", "green", "blue"])])))
        #expect(answers.map(\.id) == ["red", "green", "blue"])
        #expect(answers.map(\.title) == ["Red", "Green", "Blue"])
        #expect(answers.allSatisfy { $0.field == "q" })
        #expect(answers[1].content() == ["q": .string("green")])
    }

    /// A question tool's choice with its optional note beside it is still one tap.
    @Test func aChoiceWithItsOptionalNoteIsStillButtons() throws {
        let answers = try #require(QuickAnswer.answers(for: form([
            choice("question_0", ["yes", "no"]), text("question_0_custom", required: false),
        ])))
        #expect(answers.map(\.id) == ["yes", "no"])
        // The note left empty is a whole answer the daemon takes.
        let schema = ElicitationSchema(properties: [choice("question_0", ["yes", "no"]),
                                                    text("question_0_custom", required: false)])
        #expect(schema.problems(with: answers[0].content() ?? [:]).isEmpty)
    }

    @Test func oneChoiceOfOneOrFiveOptionsHasNone() {
        #expect(QuickAnswer.answers(for: form([choice("q", ["only"])])) == nil)
        #expect(QuickAnswer.answers(for: form([choice("q", ["a", "b", "c", "d", "e"])])) == nil)
    }

    @Test func oneFreeTextFieldIsAReply() throws {
        let answers = try #require(QuickAnswer.answers(for: form([text("name")])))
        #expect(answers.count == 1)
        #expect(answers[0].kind == .reply)
        #expect(answers[0].content(typed: "  Ada  ") == ["name": .string("Ada")])
        #expect(answers[0].content(typed: "   ") == nil)
        #expect(answers[0].content(typed: nil) == nil)
    }

    @Test func aFormOrAPageOpensTheCard() {
        #expect(QuickAnswer.answers(for: form([text("first"), text("last")])) == nil)
        #expect(QuickAnswer.answers(for: form([choice("a", ["x", "y"]), choice("b", ["x", "y"])])) == nil)
        #expect(QuickAnswer.answers(for: form([.init(name: "n", kind: .integer(minimum: nil, maximum: nil))])) == nil)
        #expect(QuickAnswer.answers(for: form([.init(name: "e", kind: .string(format: .email, minLength: nil,
                                                                              maxLength: nil, choices: nil))])) == nil)
        let page = ElicitationRequest(agentID: agentID, mode: .url("https://example.com"))
        #expect(QuickAnswer.answers(for: page) == nil)
    }

    @Test func titlesAreCutAndNeverEmpty() {
        let long = QuickAnswer(kind: .choice, id: "x", title: String(repeating: "a", count: 90)).truncating()
        #expect(long.title.count == QuickAnswer.titleBudget)
        #expect(long.title.hasSuffix("…"))
        #expect(QuickAnswer(kind: .choice, id: "x", title: "  ").truncating().title == "x")
        #expect(QuickAnswer(kind: .reply, id: "", title: "").truncating().title == "Reply")
    }

    /// The answers ride inside the sealed headline. One from a daemon before #1170 has
    /// none, and still opens.
    @Test func theHeadlineCarriesThemAndAnOldOneStillReads() throws {
        let answers = [QuickAnswer(kind: .choice, id: "once", title: String(repeating: "b", count: 60))]
        let headline = Headline(h1: "p", h2: "a", h3: "w", answers: answers).truncating()
        #expect(headline.answers?.first?.title.count == QuickAnswer.titleBudget)
        let round = try JSONDecoder().decode(Headline.self, from: JSONEncoder().encode(headline))
        #expect(round == headline)
        let old = try JSONDecoder().decode(Headline.self, from: Data(#"{"h1":"p","h2":"a","h3":"w"}"#.utf8))
        #expect(old.answers == nil)
    }

    @Test func theSameButtonsAreTheSameCategory() {
        let a = [QuickAnswer(kind: .choice, id: "1", title: "Allow"), QuickAnswer(kind: .choice, id: "2", title: "Deny")]
        let b = [QuickAnswer(kind: .choice, id: "9", title: "Allow"), QuickAnswer(kind: .choice, id: "8", title: "Deny")]
        let c = [QuickAnswer(kind: .choice, id: "1", title: "Deny"), QuickAnswer(kind: .choice, id: "2", title: "Allow")]
        #expect(QuickAnswer.categoryID(for: a) == QuickAnswer.categoryID(for: b))
        #expect(QuickAnswer.categoryID(for: a) != QuickAnswer.categoryID(for: c))
    }

    @Test func aPressReadsItsAnswerBack() throws {
        let answers = [QuickAnswer(kind: .choice, id: "once", title: "Allow"),
                       QuickAnswer(kind: .reply, id: "", title: "Reply", field: "q")]
        let userInfo: [AnyHashable: Any] = ["needToken": "permission:X",
                                            QuickAnswer.userInfoKey: try #require(QuickAnswer.userInfoValue(answers))]
        #expect(QuickAnswer.answers(inUserInfo: userInfo) == answers)
        #expect(QuickAnswer.index(ofAction: QuickAnswer.actionID(at: 1)) == 1)
        #expect(QuickAnswer.index(ofAction: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #if canImport(UserNotifications)
        let chosen = try #require(BannerAnswers.chosen(actionIdentifier: QuickAnswer.actionID(at: 1), userInfo: userInfo,
                                                       requestIdentifier: "push-id", typed: "hello"))
        #expect(chosen.token == "permission:X")
        #expect(chosen.answer == answers[1])
        #expect(chosen.typed == "hello")
        #expect(BannerAnswers.chosen(actionIdentifier: QuickAnswer.actionID(at: 7), userInfo: userInfo,
                                     requestIdentifier: "push-id", typed: nil) == nil)
        #endif
    }

    // MARK: The daemon

    private func editPermission() -> JSONValue {
        .object([
            "toolCall": .object([
                "toolCallId": .string("c1"), "title": .string("Edit notes.txt"), "kind": .string("edit"),
                "status": .string("pending"), "rawInput": .object(["path": .string("notes.txt")]),
            ]),
            "options": .array([
                .object(["optionId": .string("allow_once"), "name": .string("Allow Once"), "kind": .string("allow_once")]),
                .object(["optionId": .string("reject_once"), "name": .string("Deny"), "kind": .string("reject_once")]),
            ]),
        ])
    }

    /// The need's headline has the buttons, and a press that comes after the question was
    /// answered somewhere else is refused, with no crash and nothing else changed.
    @Test func theNeedHasItsButtonsAndALateAnswerIsRefused() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuickAnswer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.permission = editPermission()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        _ = try await core.setClientPermissions(.init(cursor: .default, grok: .default))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit"))
        try await waitFor { !(await core.pendingPermissionRequests()).isEmpty }
        let request = try #require(await core.pendingPermissionRequests().first)

        let need = try #require(await core.needs().first { $0.id == .permission(request.id) })
        let answers = try #require(need.headline.answers)
        #expect(answers.map(\.id) == ["allow_once", "reject_once"])
        #expect(answers.map(\.isDestructive) == [false, true])

        // Answered on the Mac's card first.
        try await core.answerPermission(.init(permissionID: request.id, optionID: "allow_once"))
        #expect(await core.needs().contains { $0.id == .permission(request.id) } == false)
        // Then the banner's Deny, late: refused, and the first answer stands.
        await #expect(throws: JSONRPCError.self) {
            try await core.answerPermission(.init(permissionID: request.id, optionID: answers[1].id))
        }
        try await waitFor { await core.agent(id)?.endedReason != nil }
        let page = try await core.transcript(.init(agentID: id))
        let answered = page.entries.compactMap { entry -> String? in
            if case .permissionAnswered(let optionID, _) = entry.kind { return optionID } else { return nil }
        }
        #expect(answered == ["allow_once"])
    }

    private func waitFor(_ check: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out")
    }
}
