import XCTest
@testable import QuestionsFeature

/// Which questions are answerable from the banner, and which must open the
/// window. Getting this wrong is not cosmetic: a banner that offers buttons
/// for a multi-part question would record an answer to only part of it.
final class QuestionNotificationTests: XCTestCase {

    private func question(
        _ asked: [AskedQuestion],
        state: Question.State = .pending
    ) -> Question {
        Question(
            id: "x", sessionId: nil, requester: "t", context: nil,
            questions: asked, answers: nil, state: state, answeredBy: nil,
            answeredAt: nil,
            expiresAt: "2026-09-15 09:00:00", createdAt: "2026-09-15 05:00:00"
        )
    }

    private func choice(_ labels: [String], multi: Bool = false) -> AskedQuestion {
        AskedQuestion(
            id: "q1", question: "Pick", header: nil, kind: .choice,
            options: labels.map { QuestionOption(label: $0, description: nil, preview: nil) },
            multiSelect: multi, default: nil
        )
    }

    func testASingleShortChoiceIsAnswerableInline() {
        let options = QuestionNotification.inlineOptions(for: question([choice(["Yes", "No"])]))
        XCTAssertEqual(options, ["Yes", "No"])
    }

    func testMultiPartQuestionsAreNotAnswerableInline() {
        // Two questions, one banner: answering "Yes" would settle only the
        // first and silently discard the second.
        let two = question([choice(["Yes", "No"]), choice(["A", "B"])])
        XCTAssertTrue(QuestionNotification.inlineOptions(for: two).isEmpty)
    }

    func testFreeTextIsNotAnswerableInline() {
        let text = AskedQuestion(
            id: "q1", question: "Why?", header: nil, kind: .text,
            options: nil, multiSelect: false, default: nil
        )
        XCTAssertTrue(QuestionNotification.inlineOptions(for: question([text])).isEmpty)
    }

    func testMultiSelectIsNotAnswerableInline() {
        // A banner button is a single tap; it cannot express "these two".
        XCTAssertTrue(
            QuestionNotification.inlineOptions(for: question([choice(["A", "B"], multi: true)])).isEmpty
        )
    }

    func testLongOptionListsFallBackToOpeningTheApp() {
        let many = choice(["A", "B", "C", "D", "E"])
        XCTAssertTrue(QuestionNotification.inlineOptions(for: question([many])).isEmpty)
    }

    /// The action identifier carries the label, so the handler can recover it
    /// without a lookup table that could drift out of step with the banner.
    func testActionIdentifiersRoundTrip() {
        let identifier = QuestionNotification.choiceAction(for: "Use Postgres")
        XCTAssertEqual(QuestionNotification.label(fromAction: identifier), "Use Postgres")
    }

    func testNonChoiceActionsYieldNoLabel() {
        XCTAssertNil(QuestionNotification.label(fromAction: QuestionNotification.openAction))
        XCTAssertNil(QuestionNotification.label(fromAction: "something.else"))
    }

    /// Distinct option sets must get distinct categories, or macOS reuses the
    /// first registration and every later banner shows the wrong buttons.
    func testCategoriesAreKeyedByTheirOptions() {
        XCTAssertNotEqual(
            QuestionNotification.categoryIdentifier(for: ["Yes", "No"]),
            QuestionNotification.categoryIdentifier(for: ["Ours", "Theirs"])
        )
        XCTAssertEqual(
            QuestionNotification.categoryIdentifier(for: ["Yes", "No"]),
            QuestionNotification.categoryIdentifier(for: ["Yes", "No"])
        )
    }

    func testCategoryCarriesAnOpenActionEvenWithNoOptions() {
        let category = QuestionNotification.makeCategory(labels: [])
        XCTAssertEqual(category.actions.map(\.identifier), [QuestionNotification.openAction])
    }
}
