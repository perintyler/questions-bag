import XCTest
@testable import Questions

/// Drafts and defaults.
///
/// The app polls every 5 seconds while someone is typing into it. These pin the
/// two behaviours that make that safe, both of which fail silently and both of
/// which would make the app worse than not having it.
@MainActor
final class AnswerDraftTests: XCTestCase {

    private func store() -> AppStore {
        AppStore(config: ServerConfig(baseURL: "http://127.0.0.1:1", secret: ""))
    }

    private func record(
        id: String = "rec1",
        state: Question.State = .pending,
        questions: [AskedQuestion]
    ) -> Question {
        Question(
            id: id, sessionId: nil, requester: "agent", context: nil,
            questions: questions, answers: nil, state: state,
            answeredBy: nil, answeredAt: nil,
            expiresAt: "2026-09-16 12:00:00", createdAt: "2026-09-16 08:00:00"
        )
    }

    private func choice(
        id: String, multi: Bool = false, default def: String? = nil
    ) -> AskedQuestion {
        AskedQuestion(
            id: id, question: "pick one", kind: .choice,
            options: [.init(label: "a"), .init(label: "b")],
            multiSelect: multi, default: def
        )
    }

    private func freeText(id: String) -> AskedQuestion {
        AskedQuestion(id: id, question: "say something", kind: .text, options: nil, multiSelect: false)
    }

    /// The single most important behaviour in the app: a poll landing while
    /// someone types must not discard what they have entered.
    func testARefreshDoesNotClobberAnInProgressAnswer() {
        let s = store()
        let asked = freeText(id: "q1")
        s.setRecordsForTesting([record(questions: [asked])])

        s.setText("half a thought", for: asked)
        // Same records arriving again, exactly as a poll would deliver them.
        s.setRecordsForTesting([record(questions: [asked])])

        XCTAssertEqual(s.text(for: asked), "half a thought",
                       "a poll discarded the reader's draft")
    }

    func testARefreshDoesNotClobberASelection() {
        let s = store()
        let asked = choice(id: "q1")
        s.setRecordsForTesting([record(questions: [asked])])

        s.toggle("b", for: asked)
        s.setRecordsForTesting([record(questions: [asked])])

        XCTAssertTrue(s.isSelected("b", for: asked))
    }

    /// A declared default pre-selects once, as a convenience.
    func testDefaultIsSeededOnFirstSight() {
        let s = store()
        let asked = choice(id: "q1", default: "b")
        s.setRecordsForTesting([record(questions: [asked])])
        XCTAssertTrue(s.isSelected("b", for: asked))
    }

    /// ...and never again. Re-seeding every poll would silently reinstate the
    /// default five seconds after a deliberate deselection.
    func testDefaultIsNotReSeededAfterTheReaderClearsIt() {
        let s = store()
        let asked = choice(id: "q1", default: "b")
        s.setRecordsForTesting([record(questions: [asked])])
        XCTAssertTrue(s.isSelected("b", for: asked))

        s.toggle("b", for: asked)               // deliberately clear it
        XCTAssertFalse(s.isSelected("b", for: asked))

        s.setRecordsForTesting([record(questions: [asked])])  // poll
        XCTAssertFalse(s.isSelected("b", for: asked),
                       "the poll reinstated a default the reader had cleared")
    }

    /// Single-select replaces; multi-select accumulates.
    func testSingleSelectReplacesAndMultiSelectAccumulates() {
        let s = store()
        let single = choice(id: "q1")
        let multi = choice(id: "q2", multi: true)
        s.setRecordsForTesting([record(questions: [single, multi])])

        s.toggle("a", for: single)
        s.toggle("b", for: single)
        XCTAssertFalse(s.isSelected("a", for: single))
        XCTAssertTrue(s.isSelected("b", for: single))

        s.toggle("a", for: multi)
        s.toggle("b", for: multi)
        XCTAssertTrue(s.isSelected("a", for: multi))
        XCTAssertTrue(s.isSelected("b", for: multi))
    }

    /// Every question must be answered before the record can be sent — a
    /// partial reply would hand the agent a decision nobody made.
    func testIsCompleteRequiresEveryQuestion() {
        let s = store()
        let one = choice(id: "q1")
        let two = freeText(id: "q2")
        let rec = record(questions: [one, two])
        s.setRecordsForTesting([rec])

        XCTAssertFalse(s.isComplete(rec))
        s.toggle("a", for: one)
        XCTAssertFalse(s.isComplete(rec), "still missing the free-text answer")
        s.setText("done", for: two)
        XCTAssertTrue(s.isComplete(rec))
    }

    /// Whitespace is not an answer.
    func testBlankFreeTextDoesNotCountAsComplete() {
        let s = store()
        let asked = freeText(id: "q1")
        let rec = record(questions: [asked])
        s.setRecordsForTesting([rec])

        s.setText("   \n ", for: asked)
        XCTAssertFalse(s.isComplete(rec))
    }

    /// A seeded default IS a real pre-selection the reader can just accept —
    /// but it only counts because it is visible on screen, not because the app
    /// answered on their behalf. (An unanswered question expires instead; the
    /// service never substitutes the default.)
    func testASeededDefaultMakesTheRecordSendable() {
        let s = store()
        let asked = choice(id: "q1", default: "a")
        let rec = record(questions: [asked])
        s.setRecordsForTesting([rec])
        XCTAssertTrue(s.isComplete(rec))
        XCTAssertEqual(s.answers(for: rec).first?.selected, ["a"])
    }

    func testPendingAndSettledAreSeparated() {
        let s = store()
        s.setRecordsForTesting([
            record(id: "a", state: .pending, questions: [choice(id: "q1")]),
            record(id: "b", state: .answered, questions: [choice(id: "q2")]),
            record(id: "c", state: .expired, questions: [choice(id: "q3")]),
        ])
        XCTAssertEqual(s.pending.map(\.id), ["a"])
        XCTAssertEqual(s.settled.map(\.id), ["b", "c"])
    }
}
