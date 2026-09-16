import XCTest
@testable import Questions

/// Decoding pinned to payloads copied from the REAL service.
///
/// The store persists the `questions` payload verbatim — only the MCP `ask`
/// tool mints ids and infers `kind` — so records created over HTTP arrive with
/// nulls where the macOS model expects values. These tests exist because a
/// direct port of that model fails on real rows.
final class QuestionDecodingTests: XCTestCase {

    /// Shape taken from `GET /questions` on the live service: a record created
    /// over HTTP, with kind/multiSelect absent entirely.
    private let sparse = """
    [{
      "id": "1386f0a1-6220-4e64-840a-286f7c2ac90a",
      "session_id": null,
      "requester": "ios-surface-check",
      "context": null,
      "questions": [{ "question": "probe", "options": [{"label":"a"},{"label":"b"}] }],
      "answers": null,
      "state": "pending",
      "answered_by": null,
      "answered_at": null,
      "expires_at": "2026-09-16 07:34:19",
      "created_at": "2026-09-16 07:29:19"
    }]
    """

    /// Shape the `ask` tool produces: ids minted, kind inferred, multiSelect set.
    private let rich = """
    [{
      "id": "f34e0132-42c3-4c86-a16b-b3670fdc35fd",
      "session_id": "3WuIyXPxZjsh5IZOgGYV0",
      "requester": "planning",
      "context": "Two findings drive these questions.",
      "questions": [{
        "id": "66e892b5-ee57-4682-a161-07e746d4a1a0",
        "question": "How should the service become reachable?",
        "header": "Reachability",
        "kind": "choice",
        "multiSelect": false,
        "default": "Caddy vhost",
        "options": [
          {"label":"Caddy vhost","description":"Add a host to bag.yaml","preview":"services:\\n  api:\\n    host: questions.barry.lan"},
          {"label":"Bind to the tailnet","description":"Listen on 0.0.0.0"}
        ]
      }],
      "answers": null,
      "state": "pending",
      "answered_by": null,
      "answered_at": null,
      "expires_at": "2026-09-16 04:17:44",
      "created_at": "2026-09-16 02:17:44"
    }]
    """

    /// THE test that justifies not porting the macOS model as-is. Its fields
    /// are non-optional, so this payload fails outright there.
    func testDecodesARecordWithNoKindNoMultiSelectNoIds() throws {
        let asked = try XCTUnwrap(decode(sparse).first?.questions.first)
        XCTAssertEqual(asked.question, "probe")
        XCTAssertEqual(asked.multiSelect, false, "absent multiSelect must default to false")
        XCTAssertFalse(asked.id.isEmpty, "a missing id must be synthesised — the answer POST is keyed by it")
    }

    /// Mirrors `inferKind` in src/tools.ts: options mean a choice.
    func testInfersChoiceWhenOptionsArePresent() throws {
        let asked = try XCTUnwrap(decode(sparse).first?.questions.first)
        XCTAssertEqual(asked.kind, .choice)
        XCTAssertFalse(asked.isFreeText)
    }

    func testInfersTextWhenNoOptions() throws {
        let payload = sparse.replacingOccurrences(
            of: #""options": [{"label":"a"},{"label":"b"}]"#, with: #""options": []"#
        )
        let asked = try XCTUnwrap(decode(payload).first?.questions.first)
        XCTAssertEqual(asked.kind, .text)
        XCTAssertTrue(asked.isFreeText)
    }

    func testDecodesTheRichShapeFromTheAskTool() throws {
        let record = try XCTUnwrap(decode(rich).first)
        XCTAssertEqual(record.sessionId, "3WuIyXPxZjsh5IZOgGYV0")
        XCTAssertEqual(record.state, .pending)

        let asked = try XCTUnwrap(record.questions.first)
        XCTAssertEqual(asked.id, "66e892b5-ee57-4682-a161-07e746d4a1a0")
        XCTAssertEqual(asked.kind, .choice)
        XCTAssertEqual(asked.header, "Reachability")
        XCTAssertEqual(asked.default, "Caddy vhost")
        XCTAssertEqual(asked.options?.count, 2)
        XCTAssertEqual(asked.options?.first?.description, "Add a host to bag.yaml")
        XCTAssertTrue(asked.options?.first?.preview?.contains("questions.barry.lan") ?? false)
        // The second option has neither — both are optional on the wire.
        XCTAssertNil(asked.options?.last?.preview)
    }

    /// Timestamps are SQLite `datetime('now')` output in UTC, NOT ISO8601.
    /// An ISO8601 parser returns nil for these and the countdown vanishes.
    func testParsesSqliteTimestamps() throws {
        let record = try XCTUnwrap(decode(rich).first)
        let expires = try XCTUnwrap(record.expiresAtDate, "SQLite datetime must parse")
        let created = try XCTUnwrap(record.createdAtDate)
        XCTAssertEqual(expires.timeIntervalSince(created), 2 * 3600, accuracy: 1)
    }

    func testDecodesEverySettledState() throws {
        for state in ["answered", "expired", "dismissed"] {
            let payload = sparse.replacingOccurrences(of: #""state": "pending""#, with: #""state": "\#(state)""#)
            let record = try XCTUnwrap(decode(payload).first)
            XCTAssertFalse(record.isPending, "\(state) must not read as pending")
        }
    }

    /// The three unanswered states must stay distinct: `expired` means nobody
    /// was reached, `dismissed` means a human declined. Collapsing them would
    /// hide a broken delivery path behind "they said no".
    func testExpiredAndDismissedAreNotTheSame() throws {
        let expired = try XCTUnwrap(decode(sparse.replacingOccurrences(of: #""state": "pending""#, with: #""state": "expired""#)).first)
        let dismissed = try XCTUnwrap(decode(sparse.replacingOccurrences(of: #""state": "pending""#, with: #""state": "dismissed""#)).first)
        XCTAssertNotEqual(expired.state, dismissed.state)
    }

    func testDecodesAnAnsweredRecordWithItsAnswers() throws {
        let payload = sparse
            .replacingOccurrences(of: #""state": "pending""#, with: #""state": "answered""#)
            .replacingOccurrences(of: #""answers": null"#, with: #""answers": [{"questionId":"q1","selected":["a"]}]"#)
            .replacingOccurrences(of: #""answered_by": null"#, with: #""answered_by": "ios""#)
        let record = try XCTUnwrap(decode(payload).first)
        XCTAssertEqual(record.answeredBy, "ios")
        XCTAssertEqual(record.answers?.first?.selected, ["a"])
    }

    private func decode(_ json: String) -> [Question] {
        (try? JSONDecoder().decode([Question].self, from: Data(json.utf8))) ?? []
    }
}
