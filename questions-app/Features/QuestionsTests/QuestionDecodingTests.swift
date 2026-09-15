import XCTest
@testable import QuestionsFeature

/// The model and `src/types.ts` are two descriptions of one payload, and
/// nothing makes them agree at compile time. A drifting field shows up as an
/// app that renders nothing rather than as an error — so these decode payloads
/// copied verbatim from real service responses.
final class QuestionDecodingTests: XCTestCase {

    /// Captured from `GET /questions` against a running service.
    private let pendingChoice = """
    [{
      "id": "f3e27b66-a251-4e36-88d7-6d26cf85e09c",
      "session_id": null,
      "requester": "merge-worktree",
      "context": "Both sides rewrote the retry loop.",
      "questions": [
        {
          "id": "q1",
          "question": "Which retry implementation should survive the merge?",
          "header": "Retry loop",
          "kind": "choice",
          "multiSelect": false,
          "options": [
            { "label": "Ours", "description": "Backoff with jitter", "preview": "await sleep(2 ** i)" },
            { "label": "Theirs", "description": "Fixed interval" }
          ]
        },
        { "id": "q2", "question": "Anything else?", "kind": "text", "multiSelect": false }
      ],
      "answers": null,
      "state": "pending",
      "answered_by": null,
      "answered_at": null,
      "expires_at": "2026-09-15 09:05:54",
      "created_at": "2026-09-15 05:05:54"
    }]
    """

    func testDecodesAPendingQuestion() throws {
        let questions = try JSONDecoder().decode([Question].self, from: Data(pendingChoice.utf8))
        let question = try XCTUnwrap(questions.first)

        XCTAssertEqual(question.state, .pending)
        XCTAssertTrue(question.isPending)
        XCTAssertEqual(question.requester, "merge-worktree")
        XCTAssertNil(question.sessionId)
        XCTAssertEqual(question.questions.count, 2)
        XCTAssertEqual(question.questions[0].options?.first?.preview, "await sleep(2 ** i)")
    }

    func testFreeTextIsRecognisedByAbsentOptions() throws {
        let questions = try JSONDecoder().decode([Question].self, from: Data(pendingChoice.utf8))
        let question = try XCTUnwrap(questions.first)

        XCTAssertFalse(question.questions[0].isFreeText)
        XCTAssertTrue(question.questions[1].isFreeText)
    }

    func testDecodesASettledQuestion() throws {
        let json = """
        [{
          "id": "abc", "session_id": "s1", "requester": "qa", "context": null,
          "questions": [{ "id": "q1", "question": "Which database?", "kind": "choice",
                          "multiSelect": false, "options": [{ "label": "SQLite" }] }],
          "answers": [{ "questionId": "q1", "selected": ["SQLite"], "text": null }],
          "state": "answered", "answered_by": "web",
          "answered_at": "2026-09-15 04:48:52", "expires_at": "2026-09-15 08:48:00",
          "created_at": "2026-09-15 04:48:00"
        }]
        """
        let question = try XCTUnwrap(
            try JSONDecoder().decode([Question].self, from: Data(json.utf8)).first
        )

        XCTAssertEqual(question.state, .answered)
        XCTAssertFalse(question.isPending)
        XCTAssertEqual(question.answers?.first?.selected, ["SQLite"])
        XCTAssertEqual(question.answeredBy, "web")
    }

    /// An expired question carries no answer and no answerer. Those NULLs are
    /// load-bearing: they are how the UI tells a real reply from a timeout.
    func testExpiredCarriesNoAnswer() throws {
        let json = """
        [{
          "id": "abc", "session_id": null, "requester": "qa", "context": null,
          "questions": [{ "id": "q1", "question": "Deploy?", "kind": "choice",
                          "multiSelect": false, "default": "Yes",
                          "options": [{ "label": "Yes" }, { "label": "No" }] }],
          "answers": null, "state": "expired", "answered_by": null,
          "answered_at": null, "expires_at": "2026-09-15 04:00:00",
          "created_at": "2026-09-15 03:00:00"
        }]
        """
        let question = try XCTUnwrap(
            try JSONDecoder().decode([Question].self, from: Data(json.utf8)).first
        )

        XCTAssertEqual(question.state, .expired)
        XCTAssertNil(question.answers)
        XCTAssertNil(question.answeredBy)
        // The declared default survives as UI metadata and is NOT an answer.
        XCTAssertEqual(question.questions[0].default, "Yes")
    }
}
