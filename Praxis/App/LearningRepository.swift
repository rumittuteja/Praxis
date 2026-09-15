import Foundation
import SwiftData

/// All SwiftData access in one place.
///
/// Views and coordinators talk to this rather than holding a `ModelContext`,
/// so queries stay in one reviewable file and the predicate quirks are
/// contained. Main-actor bound because the context it wraps is the view
/// context.
@MainActor
struct LearningRepository {

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Learners

    func learners() -> [Learner] {
        let descriptor = FetchDescriptor<Learner>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func learner(id: UUID) -> Learner? {
        let descriptor = FetchDescriptor<Learner>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func insert(_ learner: Learner) {
        context.insert(learner)
        save()
    }

    /// Remove a learner and everything belonging to them.
    ///
    /// Child records use a `learnerID` foreign key rather than a SwiftData
    /// relationship, so the cascade is explicit here. Missing one of these
    /// would leave orphaned rows that quietly count toward the next learner's
    /// statistics.
    func deleteLearner(_ learner: Learner) {
        let id = learner.id
        // Imported PDFs live on disk, not just in the store. Deleting only the
        // rows would strand the files in Application Support with nothing left
        // pointing at them, so the bytes go first.
        DocumentStore.deleteFiles(documents(for: id))
        try? context.delete(model: LibraryDocument.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: ConceptProgress.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: LessonRecord.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: QuizAttempt.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: TaskSubmission.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: DailyPlan.self, where: #Predicate { $0.learnerID == id })
        try? context.delete(model: Reflection.self, where: #Predicate { $0.learnerID == id })
        context.delete(learner)
        save()
    }

    // MARK: - Progress

    func allProgress(for learnerID: UUID) -> [ConceptProgress] {
        let descriptor = FetchDescriptor<ConceptProgress>(predicate: #Predicate { $0.learnerID == learnerID })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Concept ID to scheduling state, as plain values for the planner.
    func progressMap(for learnerID: UUID) -> [String: ReviewState] {
        Dictionary(
            allProgress(for: learnerID).map { ($0.conceptID, $0.reviewState) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Existing row, or a freshly inserted one. Progress rows are created
    /// lazily on first contact rather than seeded for all 104 concepts up
    /// front — most learners will never reach most of them.
    func progress(learnerID: UUID, conceptID: String) -> ConceptProgress {
        let key = ConceptProgress.makeKey(learnerID: learnerID, conceptID: conceptID)
        let descriptor = FetchDescriptor<ConceptProgress>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = ConceptProgress(learnerID: learnerID, conceptID: conceptID)
        context.insert(created)
        return created
    }

    // MARK: - Daily plan

    func plan(learnerID: UUID, day: Date) -> DailyPlan? {
        let key = DailyPlan.makeKey(learnerID: learnerID, day: day)
        let descriptor = FetchDescriptor<DailyPlan>(predicate: #Predicate { $0.key == key })
        return try? context.fetch(descriptor).first
    }

    func insert(_ plan: DailyPlan) {
        context.insert(plan)
        save()
    }

    func recentPlans(for learnerID: UUID, limit: Int = 30) -> [DailyPlan] {
        var descriptor = FetchDescriptor<DailyPlan>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Lessons

    func lesson(learnerID: UUID, conceptID: String) -> LessonRecord? {
        var descriptor = FetchDescriptor<LessonRecord>(
            predicate: #Predicate { $0.learnerID == learnerID && $0.conceptID == conceptID },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func lessons(for learnerID: UUID, limit: Int = 100) -> [LessonRecord] {
        var descriptor = FetchDescriptor<LessonRecord>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func insert(_ lesson: LessonRecord) {
        context.insert(lesson)
        save()
    }

    // MARK: - Quizzes and tasks

    func insert(_ attempt: QuizAttempt) {
        context.insert(attempt)
        save()
    }

    func insert(_ submission: TaskSubmission) {
        context.insert(submission)
        save()
    }

    func insert(_ reflection: Reflection) {
        context.insert(reflection)
        save()
    }

    func submissions(for learnerID: UUID, limit: Int = 100) -> [TaskSubmission] {
        var descriptor = FetchDescriptor<TaskSubmission>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func pendingSubmission(learnerID: UUID, conceptID: String) -> TaskSubmission? {
        let descriptor = FetchDescriptor<TaskSubmission>(
            predicate: #Predicate { $0.learnerID == learnerID && $0.conceptID == conceptID }
        )
        return (try? context.fetch(descriptor))?.first { $0.gradedAt == nil }
    }

    func quizAttempts(for learnerID: UUID, limit: Int = 50) -> [QuizAttempt] {
        var descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Learner-imported PDFs

    func documents(for learnerID: UUID) -> [LibraryDocument] {
        let descriptor = FetchDescriptor<LibraryDocument>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func insert(_ document: LibraryDocument) {
        context.insert(document)
        save()
    }

    /// Remove the row and the file together. Doing one without the other
    /// leaves either a dead entry or an unreachable file.
    func delete(_ document: LibraryDocument) {
        DocumentStore.deleteFile(for: document)
        context.delete(document)
        save()
    }

    // MARK: - Document corpus
    //
    // The corpus is shared across learners: it's public documentation, and
    // re-fetching it per profile would waste bandwidth and rate limit.

    func corpus() -> [DocSnapshot] {
        (try? context.fetch(FetchDescriptor<DocSnapshot>())) ?? []
    }

    func snapshot(url: String) -> DocSnapshot? {
        let descriptor = FetchDescriptor<DocSnapshot>(predicate: #Predicate { $0.url == url })
        return try? context.fetch(descriptor).first
    }

    /// Insert or update in place, so the unique URL constraint holds.
    func upsert(_ document: FetchedDocument) {
        if let existing = snapshot(url: document.url) {
            existing.title = document.title
            existing.content = document.content
            existing.etag = document.etag
            existing.lastModified = document.lastModified
            existing.fetchedAt = Date()
            existing.conceptTags = document.conceptTags
            existing.isDiscovered = document.isDiscovered
            existing.approximateTokens = max(1, document.content.count / 4)
        } else {
            context.insert(DocSnapshot(
                url: document.url,
                source: document.source,
                title: document.title,
                content: document.content,
                etag: document.etag,
                lastModified: document.lastModified,
                conceptTags: document.conceptTags,
                isDiscovered: document.isDiscovered
            ))
        }
    }

    /// Touch the fetch date on a 304 so the entry doesn't stay marked stale.
    func markFresh(url: String) {
        snapshot(url: url)?.fetchedAt = Date()
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // A failed save is a real bug, but crashing mid-session would lose
            // the learner's work. Log loudly and let the UI keep running.
            assertionFailure("SwiftData save failed: \(error)")
        }
    }
}
