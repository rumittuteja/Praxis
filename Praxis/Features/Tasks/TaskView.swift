import SwiftUI

/// The hands-on step: read the brief and the rubric, do the work elsewhere,
/// paste it back, get graded against the rubric that was visible all along.
struct TaskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppEnvironment.self) private var env

    let coordinator: SessionCoordinator

    @State private var draft = ""
    @State private var submitting = false

    private var task: TaskSubmission? { coordinator.task }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let task {
                    if task.isGraded {
                        feedback(task)
                    } else {
                        brief(task)
                        submissionEditor(task)
                    }
                } else if coordinator.isBusy {
                    ThinkingCard(message: coordinator.busyMessage ?? "Designing your task",
                                 thinking: coordinator.thinking)
                } else if let error = coordinator.errorMessage {
                    ErrorCard(message: error) { Task { await coordinator.loadTask() } }
                }
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Hands-on")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await coordinator.loadTask()
            if let existing = coordinator.task, !existing.submittedText.isEmpty {
                draft = existing.submittedText
            }
        }
    }

    // MARK: Brief

    @ViewBuilder
    private func brief(_ task: TaskSubmission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let concept = env.curriculum.concept(task.conceptID) {
                    TrackBadge(trackID: concept.trackID, label: concept.title)
                }
                Spacer()
                Text("Scope \(task.scopeTier)/5")
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
            Text(task.taskTitle)
                .font(Typeface.display(24))
                .foregroundStyle(Palette.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }

        MarkdownView(markdown: task.taskBriefMarkdown)

        if !task.rubric.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "How this is graded",
                                  subtitle: "Shown up front, not after")
                    ForEach(task.rubric) { criterion in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(criterion.title)
                                    .font(Typeface.semibold(14))
                                    .foregroundStyle(Palette.ink(scheme))
                                Spacer()
                                Text(Format.percent(criterion.weight))
                                    .font(Typeface.mono(11))
                                    .foregroundStyle(Palette.inkTertiary(scheme))
                            }
                            Text(criterion.detail)
                                .font(Typeface.body(13))
                                .foregroundStyle(Palette.inkSecondary(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func submissionEditor(_ task: TaskSubmission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your work", subtitle: placeholder(for: task.kind))
            Card(padding: 12) {
                TextEditor(text: $draft)
                    .frame(minHeight: 200)
                    .font(Typeface.mono(13))
                    .scrollContentBackground(.hidden)
                    .disabled(submitting)
            }
            if submitting {
                ThinkingCard(message: coordinator.busyMessage ?? "Grading your work",
                             thinking: coordinator.thinking)
            } else {
                if let error = coordinator.errorMessage {
                    ErrorCard(message: error)
                }
                Button("Submit for grading") {
                    submitting = true
                    Task {
                        await coordinator.submitTask(draft)
                        submitting = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func placeholder(for kind: SubmissionKind) -> String {
        switch kind {
        case .prompt:        return "Paste the prompt you wrote"
        case .code:          return "Paste your code or diff"
        case .investigation: return "Paste what you ran, what came back, and what you make of it"
        case .explanation:   return "Write it in your own words"
        }
    }

    // MARK: Feedback

    @ViewBuilder
    private func feedback(_ task: TaskSubmission) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.passed ? "Passed" : "Needs another pass")
                        .font(Typeface.semibold(18))
                        .foregroundStyle(task.passed ? Palette.success : Palette.warning)
                    Spacer()
                    Text(Format.percent(task.overallScore))
                        .font(Typeface.display(24))
                        .foregroundStyle(Palette.ink(scheme))
                }
                MasteryBar(value: task.overallScore,
                           tint: task.passed ? Palette.success : Palette.warning, height: 8)
            }
        }

        if !task.rubricScores.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Rubric")
                    ForEach(task.rubricScores) { score in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(title(for: score.criterionID, in: task))
                                    .font(Typeface.semibold(14))
                                    .foregroundStyle(Palette.ink(scheme))
                                Spacer()
                                Text(Format.percent(score.score))
                                    .font(Typeface.mono(12))
                                    .foregroundStyle(Palette.inkSecondary(scheme))
                            }
                            MasteryBar(value: score.score, height: 4)
                            Text(score.justification)
                                .font(Typeface.body(13))
                                .foregroundStyle(Palette.inkSecondary(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        MarkdownView(markdown: task.feedbackMarkdown)

        if let nextStep = task.nextStep, !nextStep.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Do this next", systemImage: "arrow.right.circle")
                        .font(Typeface.semibold(14))
                        .foregroundStyle(Palette.accent)
                    Text(MarkdownParser.inline(nextStep))
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if coordinator.showsUsage {
            UsageFooter(usage: task.usage, model: "task + grading",
                        provider: learnerProviderName, latency: 0)
        }

        Button("Done") { dismiss() }
            .buttonStyle(PrimaryButtonStyle())
    }

    private var learnerProviderName: String {
        coordinator.providerName
    }

    private func title(for criterionID: String, in task: TaskSubmission) -> String {
        task.rubric.first { $0.id == criterionID }?.title ?? criterionID
    }
}
