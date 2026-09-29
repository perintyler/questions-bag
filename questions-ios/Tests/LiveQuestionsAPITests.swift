import XCTest
@testable import Questions

/// Integration tests against the REAL local questions service. No mocks.
///
/// They create and settle their own throwaway questions with a short TTL, so
/// they never touch one a human is actually waiting on.
final class LiveQuestionsAPITests: XCTestCase {

    private var client: QuestionsClient!
    private var secret: String = ""

    override func setUp() async throws {
        try await super.setUp()

        // The instance secret, from the test's environment: nothing serves it.
        // Run with `TEST_RUNNER_BARRY_SECRET=... xcodebuild test ...`, which
        // xcodebuild passes to the test process as BARRY_SECRET.
        guard let value = ProcessInfo.processInfo.environment["BARRY_SECRET"], !value.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_BARRY_SECRET to run the live tests")
        }
        secret = value
        client = QuestionsClient(config: ServerConfig(
            baseURL: "http://127.0.0.1:3869", secret: secret
        ))
    }

    /// Create a throwaway question and return its record id.
    private func createQuestion() async throws -> String {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:3869/questions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "requester": "questions-ios test",
            "ttl_minutes": 5,
            "questions": [["id": "q1", "question": "probe",
                           "options": [["label": "a"], ["label": "b"]]]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["id"] as? String)
    }

    func testListDecodesTheRealStore() async throws {
        let all = try await client.questions()
        XCTAssertFalse(all.isEmpty, "the store has history; a decode failure would show as empty")
    }

    /// Every record in the live store must decode. This is the test that would
    /// have caught the null `kind` / null `id` rows.
    func testEveryStoredRecordDecodes() async throws {
        let all = try await client.questions()
        for record in all {
            XCTAssertFalse(record.id.isEmpty)
            for asked in record.questions {
                XCTAssertFalse(asked.id.isEmpty, "record \(record.id) has a question with no usable id")
            }
        }
    }

    func testHealthNeedsNoSecret() async throws {
        let unauthenticated = QuestionsClient(config: ServerConfig(
            baseURL: "http://127.0.0.1:3869", secret: ""
        ))
        let healthy = try await unauthenticated.health()
        XCTAssertTrue(healthy)
    }

    /// A list WITHOUT the secret must be refused — otherwise the app's auth is
    /// decorative and nothing would notice.
    func testListRequiresTheSecret() async throws {
        let unauthenticated = QuestionsClient(config: ServerConfig(
            baseURL: "http://127.0.0.1:3869", secret: ""
        ))
        do {
            _ = try await unauthenticated.questions()
            XCTFail("the service served questions with no credential")
        } catch let error as QuestionsError {
            guard case .http(let code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, 401)
        }
    }

    /// The whole point of the backend change: `answered_by: "ios"` is accepted.
    /// Before it, this returned 400.
    func testAnsweringAsIosIsAccepted() async throws {
        let id = try await createQuestion()
        let outcome = try await client.answer(
            id: id, answers: [QuestionAnswer(questionId: "q1", selected: ["a"])]
        )
        guard case .settled(let record) = outcome else {
            return XCTFail("expected a clean settle, got \(outcome)")
        }
        XCTAssertEqual(record.state, .answered)
        XCTAssertEqual(record.answeredBy, "ios")
    }

    /// The race the UI must render as an outcome rather than an error.
    func testSecondAnswerReportsAlreadySettledWithTheWinner() async throws {
        let id = try await createQuestion()
        _ = try await client.answer(id: id, answers: [QuestionAnswer(questionId: "q1", selected: ["a"])])

        let outcome = try await client.answer(
            id: id, answers: [QuestionAnswer(questionId: "q1", selected: ["b"])]
        )
        guard case .alreadySettled(let record) = outcome else {
            return XCTFail("a 409 was not surfaced as alreadySettled: \(outcome)")
        }
        XCTAssertEqual(record.answers?.first?.selected, ["a"], "the FIRST answer must stand")
    }

    func testDismissIsDistinctFromAnswering() async throws {
        let id = try await createQuestion()
        let outcome = try await client.dismiss(id: id)
        guard case .settled(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.state, .dismissed)
        XCTAssertNil(record.answers, "a dismissal is not an answer")
    }
}
