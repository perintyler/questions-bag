import SwiftUI
import Components

/// The window: everything waiting on an answer, and what has been settled.
public struct QuestionsView: View {
    @Bindable var state: QuestionsState

    public init(state: QuestionsState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = state.loadError {
                    // Distinct from "nothing to answer" on purpose: this one
                    // may mean an agent is blocked right now with nobody able
                    // to see the question.
                    banner(
                        title: "Cannot reach the questions service",
                        detail: "\(error)\n\nAn agent may be waiting on an answer nobody can see.",
                        tint: Palette.red
                    )
                }

                if let warning = state.deliveryWarning {
                    banner(title: "Questions are not reaching you as banners", detail: warning, tint: Palette.amber)
                }

                if state.pending.isEmpty && state.loadError == nil {
                    VStack(spacing: 6) {
                        Text("Nothing to answer.")
                            .font(AppFont.sans(size: 14, weight: .medium))
                        Text("Questions from agent sessions show up here.")
                            .font(AppFont.sans(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                }

                ForEach(state.pending) { question in
                    QuestionCard(question: question, state: state)
                }

                if !state.settled.isEmpty {
                    Text("Settled")
                        .font(AppFont.mono(size: 11))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, 12)

                    ForEach(state.settled) { question in
                        SettledRow(question: question)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.windowBackground)
        .onAppear { state.start() }
        .onDisappear { state.stop() }
    }

    private func banner(title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppFont.sans(size: 13, weight: .semibold))
            Text(detail).font(AppFont.sans(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35))
        )
    }
}

private struct QuestionCard: View {
    let question: Question
    @Bindable var state: QuestionsState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("PENDING")
                    .font(AppFont.mono(size: 10.5))
                    .foregroundStyle(Palette.amber)
                Text(question.requester)
                    .font(AppFont.mono(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(question.createdAt)
                    .font(AppFont.mono(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if let context = question.context {
                Text(context)
                    .font(AppFont.sans(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.separator).frame(width: 2)
                    }
            }

            ForEach(question.questions) { asked in
                AskedBlock(asked: asked, state: state)
            }

            HStack(spacing: 10) {
                Button("Answer") {
                    Task { await state.submit(question) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isComplete(question))

                // Saying "not answering" is a real reply: it tells the agent a
                // human saw this and chose not to decide, which is different
                // from silence.
                Button("Not answering") {
                    Task { await state.dismiss(question) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(Palette.expandedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.amber).frame(width: 3)
        }
    }
}

private struct AskedBlock: View {
    let asked: AskedQuestion
    @Bindable var state: QuestionsState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = asked.header {
                Text(header)
                    .font(AppFont.mono(size: 10))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.separator))
            }

            Text(asked.question).font(AppFont.sans(size: 14, weight: .medium))

            if asked.isFreeText {
                TextEditor(text: Binding(
                    get: { state.freeText[asked.id] ?? "" },
                    set: { state.freeText[asked.id] = $0 }
                ))
                .font(AppFont.sans(size: 13))
                .frame(minHeight: 72)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.separator))
            } else {
                ForEach(asked.options ?? [], id: \.label) { option in
                    OptionRow(
                        asked: asked,
                        option: option,
                        selected: (state.selections[asked.id] ?? []).contains(option.label),
                        onTap: { state.toggle(asked: asked, label: option.label) }
                    )
                }
            }
        }
        .onAppear {
            // A declared default pre-selects, and only pre-selects — it is
            // never sent on the reader's behalf. If they walk away, the
            // question expires and the agent is told exactly that.
            if let fallback = asked.default, state.selections[asked.id] == nil {
                state.selections[asked.id] = [fallback]
            }
        }
    }
}

private struct OptionRow: View {
    let asked: AskedQuestion
    let option: QuestionOption
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: indicator)
                    .foregroundStyle(selected ? Palette.amber : Color.secondary)
                    .font(.system(size: 13))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).font(AppFont.sans(size: 13.5, weight: .medium))
                    if let description = option.description {
                        Text(description)
                            .font(AppFont.sans(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    // The reason this app beats a terminal popover for a
                    // visual choice: the thing itself, next to the label.
                    if let preview = option.preview {
                        Text(preview)
                            .font(AppFont.mono(size: 11.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.windowBackground, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Palette.amber.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Palette.amber.opacity(0.6) : Palette.separator)
            )
        }
        .buttonStyle(.plain)
    }

    private var indicator: String {
        if asked.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

private struct SettledRow: View {
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(question.state.rawValue.uppercased())
                    .font(AppFont.mono(size: 10))
                    .foregroundStyle(tint)
                Text(question.requester)
                    .font(AppFont.mono(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(question.answeredBy.map { "via \($0)" } ?? "no answer")
                    .font(AppFont.mono(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Text(question.questions.first?.question ?? "")
                .font(AppFont.sans(size: 13))

            if let answers = question.answers, !answers.isEmpty {
                Text(summary(answers))
                    .font(AppFont.sans(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.expandedBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .opacity(0.75)
    }

    private var tint: Color {
        switch question.state {
        case .answered: return Palette.green
        case .expired, .dismissed: return Palette.red
        case .pending: return Palette.amber
        }
    }

    private func summary(_ answers: [QuestionAnswer]) -> String {
        answers
            .map { $0.text?.isEmpty == false ? $0.text! : $0.selected.joined(separator: ", ") }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
