import SwiftUI
import SwiftData

/// The daily dashboard: what's planned, what's done, what's next.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme

    let learner: Learner

    @State private var coordinator: SessionCoordinator?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let coordinator, let plan = coordinator.plan {
                        header(plan: plan)
                        if !env.hasCredentials { credentialsPrompt }
                        stepList(coordinator: coordinator, plan: plan)
                        if plan.isComplete { completionCard(plan: plan) }
                    } else {
                        Card { ProgressView().frame(maxWidth: .infinity) }
                    }
                }
                .padding(Metrics.gutter)
            }
            .canvasBackground()
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        env.activeLearnerID = nil
                    } label: {
                        Text(learner.avatarEmoji).font(.system(size: 20))
                    }
                    .accessibilityLabel("Switch profile")
                }
            }
        }
        .task {
            if coordinator == nil {
                let created = SessionCoordinator(
                    env: env,
                    repository: LearningRepository(context: modelContext),
                    learner: learner
                )
                created.loadToday()
                coordinator = created
            }
        }
    }

    // MARK: Header

    private func header(plan: DailyPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(Typeface.display(28))
                        .foregroundStyle(Palette.ink(scheme))
                    Text("About \(plan.estimatedMinutes) minutes")
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
                Spacer()
                if learner.currentStreak > 0 {
                    VStack(spacing: 0) {
                        Text("\(learner.currentStreak)")
                            .font(Typeface.semibold(22))
                            .foregroundStyle(Palette.accent)
                        Text("day streak")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                }
            }
            MasteryBar(value: plan.progressFraction, height: 8)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Morning" : (hour < 18 ? "Afternoon" : "Evening")
        return "\(part), \(learner.name)"
    }

    private var credentialsPrompt: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("No API credentials yet", systemImage: "key")
                    .font(Typeface.semibold(15))
                    .foregroundStyle(Palette.ink(scheme))
                Text("Warm-up reviews work offline, but lessons, quizzes and grading need either an Anthropic API key or AWS credentials. Add them in Settings.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepList(coordinator: SessionCoordinator, plan: DailyPlan) -> some View {
        VStack(spacing: Metrics.rowSpacing) {
            ForEach(plan.plannedSteps, id: \.self) { step in
                NavigationLink {
                    destination(step: step, coordinator: coordinator)
                } label: {
                    StepRow(
                        step: step,
                        subtitle: subtitle(for: step, plan: plan),
                        isDone: plan.completedSteps.contains(step),
                        isNext: plan.nextStep == step
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func destination(step: SessionStep, coordinator: SessionCoordinator) -> some View {
        switch step {
        case .warmup:     WarmupView(coordinator: coordinator)
        case .lesson:     LessonView(coordinator: coordinator)
        case .quiz:       QuizView(coordinator: coordinator)
        case .task:       TaskView(coordinator: coordinator)
        case .reflection: ReflectionView(coordinator: coordinator)
        }
    }

    private func subtitle(for step: SessionStep, plan: DailyPlan) -> String {
        switch step {
        case .warmup:
            let count = plan.reviewConceptIDs.count
            return "\(count) concept\(count == 1 ? "" : "s") due for recall"
        case .lesson:
            return plan.newConceptID.flatMap { env.curriculum.concept($0)?.title } ?? "New concept"
        case .quiz:
            return "\(plan.quizConceptIDs.count) concepts, interleaved"
        case .task:
            return plan.taskConceptID.flatMap { env.curriculum.concept($0)?.title } ?? "Hands-on work"
        case .reflection:
            return "Two minutes, in your own words"
        }
    }

    private func completionCard(plan: DailyPlan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Session complete", systemImage: "checkmark.seal")
                    .font(Typeface.semibold(16))
                    .foregroundStyle(Palette.success)
                Text("Come back tomorrow — the review queue is scheduled, not arbitrary, and the spacing is doing the work.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StepRow: View {
    @Environment(\.colorScheme) private var scheme
    let step: SessionStep
    let subtitle: String
    let isDone: Bool
    let isNext: Bool

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isDone ? Palette.success.opacity(0.15) : Palette.accentWash(scheme))
                        .frame(width: 40, height: 40)
                    Image(systemName: isDone ? "checkmark" : step.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isDone ? Palette.success : Palette.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(Typeface.semibold(16))
                        .foregroundStyle(Palette.ink(scheme))
                    Text(subtitle)
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if isNext {
                    Text("NEXT")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Palette.accentWash(scheme))
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .opacity(isDone ? 0.7 : 1)
    }
}
