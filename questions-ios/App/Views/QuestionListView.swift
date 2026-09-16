import SwiftUI

struct QuestionListView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            if let error = store.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.footnote)
                }
            }

            if !store.pending.isEmpty {
                Section("Waiting on you") {
                    ForEach(store.pending) { record in
                        PendingCard(record: record)
                    }
                }
            }

            if !store.settled.isEmpty {
                Section("Settled") {
                    ForEach(store.settled.prefix(25)) { record in
                        SettledRow(record: record)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading && store.records.isEmpty {
                ProgressView()
            } else if store.hasLoadedOnce && store.pending.isEmpty && store.settled.isEmpty {
                ContentUnavailableView(
                    "Nothing to answer",
                    systemImage: "checkmark.circle",
                    description: Text("No agent is waiting on a question.")
                )
            }
        }
        // An outcome, not a failure — presented plainly rather than as an error.
        .alert(
            "Already settled",
            isPresented: .init(
                get: { store.settledUnderYou != nil },
                set: { if !$0 { store.settledUnderYou = nil } }
            )
        ) {
            Button("OK") { store.settledUnderYou = nil }
        } message: {
            if let record = store.settledUnderYou {
                Text(settledMessage(record))
            }
        }
    }

    private func settledMessage(_ record: Question) -> String {
        switch record.state {
        case .answered:
            let via = record.answeredBy.map { " via \($0)" } ?? ""
            return "Someone answered this first\(via). Their answer stands."
        case .expired:
            return "This question expired before the answer arrived. The agent was told nobody replied."
        case .dismissed:
            return "This question was dismissed. The agent was told nobody answered."
        case .pending:
            return "This question is still open."
        }
    }
}

/// A question awaiting an answer.
struct PendingCard: View {
    @EnvironmentObject private var store: AppStore
    let record: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let context = record.context, !context.isEmpty {
                Text(context)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(record.questions) { asked in
                AskedQuestionView(asked: asked)
            }

            HStack {
                Button("Not answering") {
                    Task { await store.dismiss(record) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("dismissButton")

                Spacer()

                Button("Answer") {
                    Task { await store.submit(record) }
                }
                .buttonStyle(.borderedProminent)
                // Every question must be answered first: a partial reply would
                // hand the agent a decision nobody made.
                .disabled(!store.isComplete(record))
                .accessibilityIdentifier("answerButton")
            }
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack {
            Text(record.requester)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let expires = record.expiresAtDate {
                Text(Theme.remaining(until: expires))
                    .font(.caption)
                    .foregroundStyle(Theme.urgencyColor(until: expires))
                    .accessibilityIdentifier("timeRemaining")
            }
        }
    }
}

struct AskedQuestionView: View {
    @EnvironmentObject private var store: AppStore
    let asked: AskedQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = asked.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
            Text(asked.question)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if asked.isFreeText {
                TextField("Your answer", text: Binding(
                    get: { store.text(for: asked) },
                    set: { store.setText($0, for: asked) }
                ), axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("freeTextField")
            } else {
                ForEach(asked.options ?? [], id: \.label) { option in
                    OptionRow(asked: asked, option: option)
                }
                if asked.multiSelect {
                    Text("Choose any that apply")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OptionRow: View {
    @EnvironmentObject private var store: AppStore
    let asked: AskedQuestion
    let option: QuestionOption

    private var isSelected: Bool { store.isSelected(option.label, for: asked) }

    var body: some View {
        Button {
            store.toggle(option.label, for: asked)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The reason a real UI beats a terminal popover: a diff or
                    // snippet shown beside the choice it belongs to.
                    if let preview = option.preview, !preview.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(preview)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(6)
                        }
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("option-\(option.label)")
    }

    private var symbol: String {
        if asked.multiSelect { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

struct SettledRow: View {
    let record: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.questions.first?.question ?? "(no question)")
                .font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                Text(record.state.rawValue.uppercased())
                    .foregroundStyle(Theme.tint(for: record.state))
                if let by = record.answeredBy { Text("· via \(by)") }
                Spacer()
                Text(record.requester).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let answers = record.answers, !answers.isEmpty {
                Text(answers.map(\.summary).joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private extension QuestionAnswer {
    var summary: String {
        if !selected.isEmpty { return selected.joined(separator: ", ") }
        return text ?? ""
    }
}
