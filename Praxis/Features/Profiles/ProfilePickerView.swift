import SwiftUI
import SwiftData

/// The gate: pick a learner, or create one.
///
/// Profiles are entirely local — no login, no cloud, no server. Each keeps its
/// own progress graph, review queue, and streak.
struct ProfilePickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Learner.createdAt) private var learners: [Learner]

    @State private var showingEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if learners.isEmpty {
                        Card {
                            StatusMessage(
                                symbol: "person.crop.circle.badge.plus",
                                title: "No profiles yet",
                                message: "Create one to start. Each profile tracks its own progress, so more than one person can learn on this device."
                            )
                        }
                    } else {
                        VStack(spacing: Metrics.rowSpacing) {
                            ForEach(learners) { learner in
                                Button {
                                    env.activeLearnerID = learner.id
                                } label: {
                                    ProfileRow(learner: learner, summary: summary(for: learner))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button("Add a profile") { showingEditor = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(Metrics.gutter)
            }
            .canvasBackground()
            .navigationTitle("Praxis")
            .sheet(isPresented: $showingEditor) {
                ProfileEditorView { learner in
                    LearningRepository(context: modelContext).insert(learner)
                    env.activeLearnerID = learner.id
                }
            }
        }
    }

    /// Progress numbers for the row, computed here so the row itself stays a
    /// plain value-driven view rather than holding a model context.
    private func summary(for learner: Learner) -> ProfileSummary {
        let model = MasteryModel(
            store: env.curriculum,
            progress: LearningRepository(context: modelContext).progressMap(for: learner.id)
        )
        return ProfileSummary(
            started: model.conceptsStarted,
            mastered: model.conceptsMastered,
            total: env.curriculum.allConcepts.count,
            overallMastery: model.overallMastery
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who's learning?")
                .font(Typeface.display(30))
                .foregroundStyle(Palette.ink(scheme))
            Text("AI engineering with Claude and Amazon Bedrock, a bit at a time.")
                .font(Typeface.body(15))
                .foregroundStyle(Palette.inkSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileSummary: Equatable {
    var started: Int
    var mastered: Int
    var total: Int
    var overallMastery: Double
}

private struct ProfileRow: View {
    @Environment(\.colorScheme) private var scheme
    let learner: Learner
    let summary: ProfileSummary

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Text(learner.avatarEmoji)
                    .font(.system(size: 32))
                    .frame(width: 52, height: 52)
                    .background(Palette.accentWash(scheme))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text(learner.name)
                        .font(Typeface.semibold(17))
                        .foregroundStyle(Palette.ink(scheme))
                    Text("\(summary.started) of \(summary.total) concepts started · \(summary.mastered) mastered")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                    MasteryBar(value: summary.overallMastery)
                }

                Spacer(minLength: 0)

                if learner.currentStreak > 0 {
                    VStack(spacing: 2) {
                        Text("\(learner.currentStreak)")
                            .font(Typeface.semibold(18))
                            .foregroundStyle(Palette.accent)
                        Text("day\(learner.currentStreak == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
    }
}
