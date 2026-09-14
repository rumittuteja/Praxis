import SwiftUI

/// One question at a time: answer, state confidence, then see the explanation.
///
/// Confidence is asked *before* the reveal on purpose. Comparing what the
/// learner believed against what was true is what produces the calibration
/// signal on the progress screen, and it is the part people cannot self-assess
/// without help.
struct QuizView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppEnvironment.self) private var env

    let coordinator: SessionCoordinator

    @State private var index = 0
    @State private var selected: Set<Int> = []
    @State private var written = ""
    @State private var confidence: ConfidenceLevel = .fairlySure
    @State private var revealed = false
    @State private var finishing = false

    private var items: [QuizItemRecord] { coordinator.quiz?.items ?? [] }
    private var current: QuizItemRecord? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if finishing {
                    ThinkingCard(message: coordinator.busyMessage ?? "Marking your answers",
                                 thinking: coordinator.thinking)
                } else if coordinator.quiz == nil {
                    if coordinator.isBusy {
                        ThinkingCard(message: coordinator.busyMessage ?? "Writing your quiz",
                                     thinking: coordinator.thinking)
                    } else if let error = coordinator.errorMessage {
                        ErrorCard(message: error) { Task { await coordinator.loadQuiz() } }
                    }
                } else if let item = current {
                    question(item)
                }
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Check yourself")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.loadQuiz() }
    }

    // MARK: Question

    @ViewBuilder
    private func question(_ item: QuizItemRecord) -> some View {
        HStack {
            if let concept = env.curriculum.concept(item.conceptID) {
                TrackBadge(trackID: concept.trackID, label: concept.title)
            }
            Spacer()
            Text("\(index + 1) of \(items.count)")
                .font(Typeface.mono(12))
                .foregroundStyle(Palette.inkTertiary(scheme))
        }

        Card(padding: 18) {
            MarkdownView(markdown: item.prompt, baseSize: 17)
        }

        switch item.kind {
        case .multipleChoice, .multipleSelect:
            options(item)
        case .shortAnswer, .critique, .prediction:
            freeText(item)
        }

        if !revealed {
            confidencePicker
            Button("Submit answer") { submit(item) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSubmit(item))
        } else {
            explanation(item)
            Button(index + 1 < items.count ? "Next question" : "Finish") { advance() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func options(_ item: QuizItemRecord) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(item.options.enumerated()), id: \.offset) { optionIndex, option in
                Button {
                    guard !revealed else { return }
                    toggle(optionIndex, multiSelect: item.kind == .multipleSelect)
                } label: {
                    OptionRow(
                        text: option,
                        isSelected: selected.contains(optionIndex),
                        verdict: revealed
                            ? (item.correctIndices.contains(optionIndex) ? .correct
                               : (selected.contains(optionIndex) ? .incorrect : .neutral))
                            : .neutral
                    )
                }
                .buttonStyle(.plain)
                .disabled(revealed)
            }
            if item.kind == .multipleSelect {
                Text("Select all that apply.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func freeText(_ item: QuizItemRecord) -> some View {
        Card(padding: 12) {
            TextEditor(text: $written)
                .frame(minHeight: 130)
                .font(Typeface.body(15))
                .scrollContentBackground(.hidden)
                .disabled(revealed)
        }
    }

    private var confidencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "How sure are you?",
                          subtitle: "Answer honestly — this is measured, not judged")
            HStack(spacing: 6) {
                ForEach(ConfidenceLevel.allCases, id: \.rawValue) { level in
                    Button {
                        confidence = level
                    } label: {
                        Text(level.label)
                            .font(Typeface.body(13))
                            .foregroundStyle(confidence == level ? Palette.onAccent : Palette.ink(scheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(confidence == level ? Palette.accent : Palette.surface(scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Palette.hairline(scheme), lineWidth: confidence == level ? 0 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func explanation(_ item: QuizItemRecord) -> some View {
        let scored = coordinator.quiz?.items.first { $0.id == item.id }
        let score = scored?.score ?? 0
        let isFreeText = item.kind == .shortAnswer || item.kind == .critique || item.kind == .prediction
        let overconfident = confidence.normalized > 0.6 && score < 0.6

        Card {
            VStack(alignment: .leading, spacing: 12) {
                if isFreeText {
                    Label("Graded after the quiz", systemImage: "clock")
                        .font(Typeface.semibold(14))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                } else {
                    Label(score >= 0.999 ? "Correct" : (score > 0 ? "Partly right" : "Not quite"),
                          systemImage: score >= 0.999 ? "checkmark.circle" : "xmark.circle")
                        .font(Typeface.semibold(15))
                        .foregroundStyle(score >= 0.999 ? Palette.success : Palette.danger)
                }

                if overconfident && !isFreeText {
                    Text("You were confident on that one. Worth a closer look — confident-and-wrong is the pattern that costs you later, because nothing tells you to go back.")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.overconfident)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isFreeText, let expected = item.expectedAnswer, !expected.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A full-credit answer covers")
                            .font(Typeface.semibold(12))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        Text(MarkdownParser.inline(expected))
                            .font(Typeface.body(14))
                            .foregroundStyle(Palette.ink(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().background(Palette.hairline(scheme))
                MarkdownView(markdown: item.explanation, baseSize: 15)
            }
        }
    }

    // MARK: Actions

    private func toggle(_ optionIndex: Int, multiSelect: Bool) {
        if multiSelect {
            if selected.contains(optionIndex) { selected.remove(optionIndex) }
            else { selected.insert(optionIndex) }
        } else {
            selected = [optionIndex]
        }
    }

    private func canSubmit(_ item: QuizItemRecord) -> Bool {
        switch item.kind {
        case .multipleChoice, .multipleSelect:
            return !selected.isEmpty
        case .shortAnswer, .critique, .prediction:
            return !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit(_ item: QuizItemRecord) {
        coordinator.answer(
            itemID: item.id,
            selected: selected.sorted(),
            written: written.isEmpty ? nil : written,
            confidence: confidence
        )
        withAnimation { revealed = true }
    }

    private func advance() {
        selected = []
        written = ""
        confidence = .fairlySure
        revealed = false

        if index + 1 < items.count {
            index += 1
        } else {
            finishing = true
            Task {
                await coordinator.finishQuiz()
                finishing = false
                dismiss()
            }
        }
    }
}

private struct OptionRow: View {
    enum Verdict { case neutral, correct, incorrect }

    @Environment(\.colorScheme) private var scheme
    let text: String
    let isSelected: Bool
    let verdict: Verdict

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(Glyph.icon(16))
                .foregroundStyle(tint)
            Text(MarkdownParser.inline(text))
                .font(Typeface.body(15))
                .foregroundStyle(Palette.ink(scheme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .stroke(borderColor, lineWidth: isSelected || verdict != .neutral ? 2 : 1)
        )
    }

    private var symbol: String {
        switch verdict {
        case .correct:   return "checkmark.circle.fill"
        case .incorrect: return "xmark.circle.fill"
        case .neutral:   return isSelected ? "largecircle.fill.circle" : "circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .correct:   return Palette.success
        case .incorrect: return Palette.danger
        case .neutral:   return isSelected ? Palette.accent : Palette.inkTertiary(scheme)
        }
    }

    private var borderColor: Color {
        switch verdict {
        case .correct:   return Palette.success
        case .incorrect: return Palette.danger
        case .neutral:   return isSelected ? Palette.accent : Palette.hairline(scheme)
        }
    }
}
