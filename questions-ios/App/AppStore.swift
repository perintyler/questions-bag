import Foundation
import SwiftUI

/// App-wide state: server config, the question list, and the answer drafts.
@MainActor
final class AppStore: ObservableObject {
    @Published var config: ServerConfig
    @Published private(set) var records: [Question] = []
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false

    /// Set when a reply lost a race — someone else answered, or the deadline
    /// passed. Kept SEPARATE from `loadError` on purpose: it is an outcome, not
    /// a failure, and showing it in red next to "could not reach the server"
    /// would teach the reader to ignore both.
    @Published var settledUnderYou: Question?

    /// In-progress answers, keyed by asked-question id.
    ///
    /// Held here rather than in the view so a poll landing mid-typing cannot
    /// discard what someone has entered. The macOS app learned this the same
    /// way; it is the single most important behaviour in the app, because
    /// losing a half-written answer is worse than not having the app.
    @Published private(set) var selections: [String: Set<String>] = [:]
    @Published private(set) var freeText: [String: String] = [:]

    /// Asked-question ids whose declared `default` has already been seeded.
    ///
    /// Seeding happens ONCE, on first sight. Re-applying it every poll would
    /// silently undo a deliberate deselection five seconds later — the reader
    /// would watch their choice revert and have no idea why.
    private var seededDefaults: Set<String> = []

    private var pollTimer: Timer?
    private var announced: Set<String> = []
    private let pollInterval: TimeInterval = 5

    var client: QuestionsClient { QuestionsClient(config: config) }

    var pending: [Question] { records.filter(\.isPending) }
    var settled: [Question] { records.filter { !$0.isPending } }

    init(config: ServerConfig = .load()) {
        self.config = config
    }

    func updateConfig(_ newConfig: ServerConfig) {
        config = newConfig
        newConfig.save()
        Task { await refresh() }
    }

    // MARK: - Lifecycle

    func start() {
        if records.isEmpty { Task { await refresh() } }
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(silently: true) }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Loading

    func refresh(silently: Bool = false) async {
        if !silently && records.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let fetched = try await client.questions()
            records = fetched
            seedDefaults(for: fetched)
            hasLoadedOnce = true
            loadError = nil
            await announceDelivery(for: fetched)
        } catch {
            if !silently { loadError = error.localizedDescription }
        }
    }

    /// Tell the service a human has actually seen each pending question, once.
    private func announceDelivery(for fetched: [Question]) async {
        for record in fetched where record.isPending && !announced.contains(record.id) {
            announced.insert(record.id)
            await client.recordDelivery(id: record.id)
        }
    }

    // MARK: - Drafts

    private func seedDefaults(for fetched: [Question]) {
        for record in fetched where record.isPending {
            for asked in record.questions {
                guard !seededDefaults.contains(asked.id) else { continue }
                seededDefaults.insert(asked.id)
                if let preset = asked.default, !preset.isEmpty, !asked.isFreeText {
                    selections[asked.id] = [preset]
                }
            }
        }
    }

    func toggle(_ label: String, for asked: AskedQuestion) {
        var current = selections[asked.id] ?? []
        if asked.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = current.contains(label) ? [] : [label]
        }
        selections[asked.id] = current
    }

    func isSelected(_ label: String, for asked: AskedQuestion) -> Bool {
        selections[asked.id]?.contains(label) ?? false
    }

    func setText(_ text: String, for asked: AskedQuestion) {
        freeText[asked.id] = text
    }

    func text(for asked: AskedQuestion) -> String { freeText[asked.id] ?? "" }

    /// Every question in the record must have an answer before it can be sent.
    /// A partially answered record would hand the agent a decision nobody made.
    func isComplete(_ record: Question) -> Bool {
        record.questions.allSatisfy { asked in
            if asked.isFreeText {
                return !text(for: asked).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !(selections[asked.id]?.isEmpty ?? true)
        }
    }

    func answers(for record: Question) -> [QuestionAnswer] {
        record.questions.map { asked in
            QuestionAnswer(
                questionId: asked.id,
                selected: Array(selections[asked.id] ?? []),
                text: asked.isFreeText ? text(for: asked) : nil
            )
        }
    }

    // MARK: - Settling

    func submit(_ record: Question) async {
        guard isComplete(record) else { return }
        await apply { try await self.client.answer(id: record.id, answers: self.answers(for: record)) }
    }

    func dismiss(_ record: Question) async {
        await apply { try await self.client.dismiss(id: record.id) }
    }

    private func apply(_ work: () async throws -> SettleOutcome) async {
        do {
            switch try await work() {
            case .settled(let record):
                replace(record)
                clearDrafts(for: record)
            case .alreadySettled(let record):
                // Not an error — show what actually stands.
                replace(record)
                clearDrafts(for: record)
                settledUnderYou = record
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func replace(_ record: Question) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }

    private func clearDrafts(for record: Question) {
        for asked in record.questions {
            selections[asked.id] = nil
            freeText[asked.id] = nil
        }
    }

    // MARK: - Test seams

    func setRecordsForTesting(_ list: [Question]) {
        records = list
        seedDefaults(for: list)
    }
}
