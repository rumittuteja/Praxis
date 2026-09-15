import SwiftUI
import SwiftData

@main
struct PraxisApp: App {

    @State private var environment: AppEnvironment
    private let container: ModelContainer

    init() {
        // Build the environment locally and seed @State with it: reading a
        // property wrapper's value inside init is not valid.
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)

        let schema = Schema([
            Learner.self,
            ConceptProgress.self,
            LessonRecord.self,
            QuizAttempt.self,
            TaskSubmission.self,
            DailyPlan.self,
            Reflection.self,
            DocSnapshot.self,
            LibraryDocument.self
        ])
        do {
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            )
        } catch {
            // Nothing useful can happen without a store, and silently falling
            // back to in-memory would lose the learner's history without
            // telling them.
            fatalError("Could not open the Praxis data store: \(error)")
        }

        #if DEBUG
        let problems = environment.curriculum.integrityProblems()
        if !problems.isEmpty {
            print("Curriculum integrity problems:\n" + problems.map { "  - \($0)" }.joined(separator: "\n"))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Palette.accent)
        }
        .modelContainer(container)
    }
}
