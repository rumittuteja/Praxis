import SwiftUI
import SwiftData

/// Where the learner stands: per-track mastery, what's decaying, and how well
/// their confidence matches their accuracy.
struct ProgressMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme

    let learner: Learner

    @State private var expandedTrack: String?

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    private var model: MasteryModel {
        MasteryModel(store: env.curriculum, progress: repository.progressMap(for: learner.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let mastery = model
                VStack(alignment: .leading, spacing: 20) {
                    headline(mastery)
                    calibration(mastery)
                    atRisk(mastery)
                    tracks(mastery)
                }
                .padding(Metrics.gutter)
            }
            .canvasBackground()
            .navigationTitle("Progress")
        }
    }

    // MARK: Headline

    private func headline(_ mastery: MasteryModel) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 20) {
                    stat("\(mastery.conceptsMastered)", "mastered")
                    stat("\(mastery.conceptsStarted)", "started")
                    stat("\(env.curriculum.allConcepts.count)", "total")
                    stat("\(mastery.dueCount)", "due now")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overall mastery")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                    MasteryBar(value: mastery.overallMastery, height: 8)
                }
                if learner.longestStreak > 0 {
                    Text("Current streak \(learner.currentStreak) · best \(learner.longestStreak) · \(learner.totalSessionsCompleted) sessions")
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Typeface.semibold(22))
                .foregroundStyle(Palette.ink(scheme))
            Text(label)
                .font(Typeface.micro())
                .foregroundStyle(Palette.inkTertiary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Calibration

    private func calibration(_ mastery: MasteryModel) -> some View {
        let bias = mastery.calibrationBias
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Calibration",
                              subtitle: "Your confidence against your accuracy")
                Text(mastery.calibrationDescription)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                // Centre line at zero, bar extending either side.
                GeometryReader { geo in
                    let width = geo.size.width
                    let clamped = min(max(bias, -1), 1)
                    let half = width / 2
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.hairline(scheme)).frame(height: 6)
                        Capsule()
                            .fill(bias > 0.1 ? Palette.overconfident : Palette.success)
                            .frame(width: abs(clamped) * half, height: 6)
                            .offset(x: clamped >= 0 ? half : half - abs(clamped) * half)
                        Rectangle()
                            .fill(Palette.inkTertiary(scheme))
                            .frame(width: 1, height: 12)
                            .offset(x: half)
                    }
                    .frame(height: 12)
                }
                .frame(height: 12)

                HStack {
                    Text("underconfident").font(Typeface.nano(.regular))
                    Spacer()
                    Text("overconfident").font(Typeface.nano(.regular))
                }
                .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
    }

    // MARK: At risk

    @ViewBuilder
    private func atRisk(_ mastery: MasteryModel) -> some View {
        let items = mastery.atRisk()
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Fading",
                                  subtitle: "Estimated recall, from the forgetting curve")
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Palette.track(item.trackID))
                                .frame(width: 6, height: 6)
                            Text(item.title)
                                .font(Typeface.body(14))
                                .foregroundStyle(Palette.ink(scheme))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int((item.retrievability * 100).rounded()))%")
                                .font(Typeface.mono(12))
                                .foregroundStyle(Palette.inkSecondary(scheme))
                        }
                    }
                }
            }
        }
    }

    // MARK: Tracks

    private func tracks(_ mastery: MasteryModel) -> some View {
        VStack(spacing: Metrics.rowSpacing) {
            SectionHeader(title: "Tracks")
            ForEach(mastery.trackSummaries()) { summary in
                TrackCard(
                    summary: summary,
                    isExpanded: expandedTrack == summary.trackID,
                    concepts: env.curriculum.concepts(inTrack: summary.trackID),
                    progress: repository.progressMap(for: learner.id),
                    curriculum: env.curriculum
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedTrack = expandedTrack == summary.trackID ? nil : summary.trackID
                    }
                }
            }
        }
    }
}

private struct TrackCard: View {
    @Environment(\.colorScheme) private var scheme
    let summary: TrackSummary
    let isExpanded: Bool
    let concepts: [Concept]
    let progress: [String: ReviewState]
    let curriculum: CurriculumStore
    let onTap: () -> Void

    private var satisfied: Set<String> {
        Set(progress.compactMap { id, state in
            (state.state == .review || state.state == .mastered) ? id : nil
        })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(summary.title)
                                .font(Typeface.semibold(16))
                                .foregroundStyle(Palette.ink(scheme))
                            Spacer()
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(Glyph.icon(11, weight: .semibold))
                                .foregroundStyle(Palette.inkTertiary(scheme))
                        }
                        Text("\(summary.mastered) mastered · \(summary.startedCount) of \(summary.total) started")
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        MasteryBar(value: summary.meanMastery, tint: Palette.track(summary.trackID))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().background(Palette.hairline(scheme))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(concepts) { concept in
                            ConceptRow(
                                concept: concept,
                                state: resolvedState(for: concept),
                                mastery: progress[concept.id]?.masteryScore ?? 0,
                                missing: curriculum.missingPrerequisites(for: concept, given: satisfied)
                            )
                        }
                    }
                }
            }
        }
    }

    private func resolvedState(for concept: Concept) -> ConceptState {
        if let state = progress[concept.id]?.state { return state }
        return curriculum.prerequisitesMet(for: concept, given: satisfied) ? .available : .locked
    }
}

private struct ConceptRow: View {
    @Environment(\.colorScheme) private var scheme
    let concept: Concept
    let state: ConceptState
    let mastery: Double
    let missing: [Concept]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(Glyph.icon(13))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(concept.title)
                        .font(Typeface.body(14))
                        .foregroundStyle(state == .locked ? Palette.inkTertiary(scheme) : Palette.ink(scheme))
                    Spacer(minLength: 4)
                    TierPips(tier: concept.tier)
                }
                if state == .locked, let first = missing.first {
                    Text("Needs \(first.title)\(missing.count > 1 ? " +\(missing.count - 1) more" : "")")
                        .font(Typeface.micro())
                        .foregroundStyle(Palette.inkTertiary(scheme))
                } else if mastery > 0 {
                    MasteryBar(value: mastery, tint: Palette.track(concept.trackID), height: 3)
                }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .locked:    return "lock"
        case .available: return "circle.dotted"
        case .learning:  return "circle.lefthalf.filled"
        case .review:    return "arrow.triangle.2.circlepath"
        case .mastered:  return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .locked:    return Palette.inkTertiary(scheme)
        case .available: return Palette.inkSecondary(scheme)
        case .learning:  return Palette.accent
        case .review:    return Palette.track(concept.trackID)
        case .mastered:  return Palette.success
        }
    }
}
