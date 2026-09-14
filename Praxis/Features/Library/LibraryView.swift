import SwiftUI
import SwiftData

/// Every lesson this learner has read, searchable. Lessons are cached rather
/// than regenerated, so revisiting one costs nothing and shows exactly the
/// text they read the first time.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme

    let learner: Learner

    @State private var search = ""

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    private var lessons: [LessonRecord] {
        let all = repository.lessons(for: learner.id)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(query)
                || $0.conceptID.lowercased().contains(query)
                || $0.keyTakeaways.joined(separator: " ").lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if lessons.isEmpty {
                    ScrollView {
                        Card {
                            StatusMessage(
                                symbol: "books.vertical",
                                title: search.isEmpty ? "Nothing here yet" : "No matches",
                                message: search.isEmpty
                                    ? "Lessons you read are kept here so you can come back to them."
                                    : "Try a different search."
                            )
                        }
                        .padding(Metrics.gutter)
                    }
                    .canvasBackground()
                } else {
                    ScrollView {
                        VStack(spacing: Metrics.rowSpacing) {
                            ForEach(lessons) { lesson in
                                NavigationLink {
                                    ArchivedLessonView(lesson: lesson)
                                } label: {
                                    row(lesson)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(Metrics.gutter)
                    }
                    .canvasBackground()
                }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search lessons")
        }
    }

    private func row(_ lesson: LessonRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if let concept = env.curriculum.concept(lesson.conceptID) {
                    TrackBadge(trackID: concept.trackID,
                               label: env.curriculum.trackTitle(concept.trackID))
                }
                Text(lesson.title)
                    .font(Typeface.semibold(16))
                    .foregroundStyle(Palette.ink(scheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = lesson.keyTakeaways.first {
                    Text(first)
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(lesson.generatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(Typeface.micro())
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
    }
}

/// Read-only view of a lesson from the archive.
struct ArchivedLessonView: View {
    @Environment(\.colorScheme) private var scheme
    let lesson: LessonRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(lesson.title)
                    .font(Typeface.display(26))
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Worked example")
                        MarkdownView(markdown: lesson.workedExampleMarkdown)
                    }
                }

                MarkdownView(markdown: lesson.bodyMarkdown)

                if !lesson.keyTakeaways.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Keep these")
                            ForEach(Array(lesson.keyTakeaways.enumerated()), id: \.offset) { _, point in
                                Text(MarkdownParser.inline("• " + point))
                                    .font(Typeface.body(15))
                                    .foregroundStyle(Palette.ink(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                UsageFooter(usage: lesson.usage, model: lesson.modelID,
                            provider: lesson.providerRaw, latency: lesson.latencySeconds)
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Lesson")
        .navigationBarTitleDisplayMode(.inline)
    }
}
