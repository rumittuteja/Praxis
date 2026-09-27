import SwiftUI
import SwiftData

/// Chooses between the profile gate and the main tabs.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Learner.createdAt) private var learners: [Learner]

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    private var activeLearner: Learner? {
        guard let id = env.activeLearnerID else { return nil }
        return learners.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let learner = activeLearner {
                MainTabView(learner: learner)
            } else {
                ProfilePickerView()
            }
        }
        .onAppear(perform: reconcileActiveLearner)
        .onChange(of: learners.count) { _, _ in reconcileActiveLearner() }
        .task {
            // Throttled to once a day internally, so this is cheap on every
            // launch and does not block the UI — the session below renders
            // from whatever syllabus is already loaded.
            await env.refreshContentIfNeeded(repository: repository)
        }
    }

    /// Keep the stored active-learner id honest: it can point at a profile that
    /// was deleted, and a single learner shouldn't have to pick every launch.
    private func reconcileActiveLearner() {
        if let id = env.activeLearnerID, !learners.contains(where: { $0.id == id }) {
            env.activeLearnerID = nil
        }
        if env.activeLearnerID == nil, learners.count == 1 {
            env.activeLearnerID = learners.first?.id
        }
    }
}

struct MainTabView: View {
    let learner: Learner
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            TodayView(learner: learner)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(0)

            ProgressMapView(learner: learner)
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(1)

            LibraryView(learner: learner)
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(2)

            SettingsView(learner: learner)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
    }
}
