import SwiftUI

/// The lesson reader. Worked example first, then explanation, then takeaways.
struct LessonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppEnvironment.self) private var env

    let coordinator: SessionCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let lesson = coordinator.lesson {
                    content(lesson)
                } else if coordinator.isBusy {
                    ThinkingCard(
                        message: coordinator.busyMessage ?? "Working",
                        thinking: coordinator.thinking
                    )
                } else if let error = coordinator.errorMessage {
                    ErrorCard(message: error) { Task { await coordinator.loadLesson() } }
                }
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Lesson")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.loadLesson() }
    }

    @ViewBuilder
    private func content(_ lesson: LessonRecord) -> some View {
        let concept = env.curriculum.concept(lesson.conceptID)

        VStack(alignment: .leading, spacing: 10) {
            if let concept {
                HStack(spacing: 8) {
                    TrackBadge(trackID: concept.trackID,
                               label: env.curriculum.trackTitle(concept.trackID))
                    TierPips(tier: concept.tier)
                }
            }
            Text(lesson.title)
                .font(Typeface.display(28))
                .foregroundStyle(Palette.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }

        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Worked example",
                              subtitle: "Read this before the explanation")
                MarkdownView(markdown: lesson.workedExampleMarkdown)
            }
        }

        MarkdownView(markdown: lesson.bodyMarkdown)

        if let misconception = lesson.addressedMisconception, !misconception.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Common trap", systemImage: "exclamationmark.triangle")
                        .font(Typeface.semibold(14))
                        .foregroundStyle(Palette.warning)
                    Text(MarkdownParser.inline(misconception))
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if !lesson.keyTakeaways.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Keep these")
                    ForEach(Array(lesson.keyTakeaways.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(Typeface.mono(12))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 16, alignment: .trailing)
                            Text(MarkdownParser.inline(point))
                                .font(Typeface.body(15))
                                .foregroundStyle(Palette.ink(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if !lesson.citations.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Sources", subtitle: "What this lesson was grounded in")
                    ForEach(lesson.citations) { citation in
                        if let url = URL(string: citation.url) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 12))
                                    Text(citation.title)
                                        .font(Typeface.body(14))
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
            }
        }

        if coordinator.showsUsage {
            UsageFooter(usage: lesson.usage, model: lesson.modelID,
                        provider: lesson.providerRaw, latency: lesson.latencySeconds)
        }

        Button(coordinator.plan?.completedSteps.contains(.lesson) == true ? "Done" : "Mark as read") {
            coordinator.markLessonRead()
            dismiss()
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// Shows the model's reasoning summary while a generation runs.
///
/// Better than a spinner in two ways: the wait has visible content, and the
/// learner sees `thinking.display: "summarized"` doing something real, which
/// is on the syllabus.
struct ThinkingCard: View {
    @Environment(\.colorScheme) private var scheme
    let message: String
    let thinking: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(Typeface.medium(15))
                        .foregroundStyle(Palette.ink(scheme))
                }
                if !thinking.isEmpty {
                    Divider().background(Palette.hairline(scheme))
                    Text(thinking)
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: 260, alignment: .top)
                        .clipped()
                }
            }
        }
    }
}

struct ErrorCard: View {
    @Environment(\.colorScheme) private var scheme
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
                    .font(Typeface.semibold(15))
                    .foregroundStyle(Palette.danger)
                Text(message)
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

/// Token accounting, shown inline. Watching this accumulate is part of
/// learning what requests cost.
struct UsageFooter: View {
    @Environment(\.colorScheme) private var scheme
    let usage: UsageStats
    let model: String
    let provider: String
    let latency: Double

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model) · \(provider) · \(String(format: "%.1f", latency))s")
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                Text("in \(usage.inputTokens) · out \(usage.outputTokens) · cache read \(usage.cacheReadInputTokens) · cache write \(usage.cacheCreationInputTokens)")
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
