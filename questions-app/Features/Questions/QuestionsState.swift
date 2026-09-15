import Foundation
import Observation

/// What the window is showing, and the polling that keeps it current.
@MainActor
@Observable
public final class QuestionsState {
    public private(set) var questions: [Question] = []
    public private(set) var loadError: String?
    /// Set when a question could not be put in front of anyone. Shown in the
    /// window, because the alternative is an agent blocked on a person who was
    /// never told they were asked.
    public private(set) var deliveryWarning: String?
    public private(set) var isLoading = false

    /// Draft answers, keyed by asked-question id, so a half-filled reply
    /// survives the poll that lands mid-typing.
    public var selections: [String: Set<String>] = [:]
    public var freeText: [String: String] = [:]

    private let client: QuestionsClient
    private var timer: Timer?
    /// Questions already banner-ed, so a refresh does not re-announce them.
    private var announced: Set<String> = []

    /// Worst-case latency from a question being asked to a banner appearing.
    /// Matches the approvals app, and is well inside the asking tool's
    /// 30-second undelivered grace period.
    private let pollInterval: TimeInterval = 5

    public init(client: QuestionsClient = QuestionsClient()) {
        self.client = client
    }

    public func start() {
        Task { await refresh() }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public var pending: [Question] { questions.filter(\.isPending) }
    public var settled: [Question] { questions.filter { !$0.isPending } }

    public func refresh() async {
        do {
            let fetched = try await client.list()
            loadError = nil
            questions = fetched

            for question in fetched where question.isPending && !announced.contains(question.id) {
                announced.insert(question.id)
                announce(question)
            }
            // Pull banners for anything that has since been settled, so a
            // stale notification cannot post a second answer.
            for question in fetched where !question.isPending {
                QuestionNotification.withdraw(questionId: question.id)
            }
        } catch {
            // Say which failure this is. "No questions" and "cannot reach the
            // service" mean opposite things — the second may mean an agent is
            // blocked right now with nobody able to see it.
            loadError = error.localizedDescription
        }
    }

    private func announce(_ question: Question) {
        let client = self.client
        QuestionNotification.submit(question) { delivered, detail in
            Task { @MainActor [weak self] in
                await client.reportDelivery(
                    id: question.id,
                    surface: "notification",
                    delivered: delivered,
                    detail: detail
                )
                // The window itself counts as delivery: it is open and showing
                // the question, so a human can see it even with banners off.
                await client.reportDelivery(id: question.id, surface: "app", delivered: true)
                if !delivered { self?.deliveryWarning = detail }
            }
        }
    }

    /// Everything asked must have something in it before the answer can go.
    public func isComplete(_ question: Question) -> Bool {
        question.questions.allSatisfy { asked in
            if asked.isFreeText {
                return !(freeText[asked.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !(selections[asked.id] ?? []).isEmpty
        }
    }

    public func toggle(asked: AskedQuestion, label: String) {
        var current = selections[asked.id] ?? []
        if asked.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = [label]
        }
        selections[asked.id] = current
    }

    public func answers(for question: Question) -> [QuestionAnswer] {
        question.questions.map { asked in
            if asked.isFreeText {
                return QuestionAnswer(questionId: asked.id, selected: [], text: freeText[asked.id] ?? "")
            }
            return QuestionAnswer(questionId: asked.id, selected: Array(selections[asked.id] ?? []))
        }
    }

    public func submit(_ question: Question) async {
        let payload = answers(for: question)
        do {
            try await client.answer(id: question.id, answers: payload)
            QuestionNotification.withdraw(questionId: question.id)
            clearDraft(for: question)
        } catch {
            loadError = error.localizedDescription
        }
        await refresh()
    }

    public func dismiss(_ question: Question) async {
        do {
            try await client.dismiss(id: question.id)
            QuestionNotification.withdraw(questionId: question.id)
            clearDraft(for: question)
        } catch {
            loadError = error.localizedDescription
        }
        await refresh()
    }

    /// Answer straight from a notification button, without opening the window.
    public func answerFromNotification(questionId: String, label: String) async {
        do {
            let question = try await client.get(id: questionId)
            guard let asked = question.questions.first else { return }
            try await client.answer(
                id: questionId,
                answers: [QuestionAnswer(questionId: asked.id, selected: [label])],
                surface: "notification"
            )
        } catch {
            loadError = error.localizedDescription
        }
        await refresh()
    }

    private func clearDraft(for question: Question) {
        for asked in question.questions {
            selections.removeValue(forKey: asked.id)
            freeText.removeValue(forKey: asked.id)
        }
    }
}
