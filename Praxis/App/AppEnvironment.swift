import Foundation
import Observation
import SwiftData

/// App-wide services and the currently selected learner.
///
/// One object injected through the environment. Views read it; coordinators
/// take what they need from it. Keeps construction in one place so a preview
/// or a test can build a variant without touching the view tree.
@MainActor
@Observable
final class AppEnvironment {

    let credentials: CredentialStore
    let providers: ProviderFactory
    let requestLog: RequestLog
    let retriever: DocsRetriever

    /// Persisted across launches so the app reopens on the last profile.
    var activeLearnerID: UUID? {
        didSet {
            UserDefaults.standard.set(activeLearnerID?.uuidString, forKey: Self.activeLearnerKey)
        }
    }

    /// Set when a sync is running, so Settings can show progress.
    var syncInProgress = false
    var lastSyncReport: SyncReport?

    /// Replaced when a newer syllabus is downloaded and adopted.
    private(set) var curriculum: CurriculumStore
    var lastCurriculumUpdate: CurriculumUpdate?
    var curriculumCheckInProgress = false
    /// Set when a curriculum check fails, so Settings can say why.
    var curriculumUpdateError: String?

    /// Discovered pages are fetched once per sync run and reused, since the
    /// indexes are large and change slowly.
    var includeDiscoveredSources = true

    /// Concepts that arrived in the most recent update and have not been
    /// shown to the learner yet. Cleared when they acknowledge the notice.
    var unacknowledgedNewConcepts: [String] = []

    private static let lastRefreshKey = "praxis.lastContentRefresh"

    private static let activeLearnerKey = "praxis.activeLearnerID"

    init(
        curriculum: CurriculumStore = .load(),
        credentials: CredentialStore = CredentialStore()
    ) {
        self.curriculum = curriculum
        self.credentials = credentials
        self.providers = ProviderFactory(credentials: credentials)
        self.requestLog = RequestLog()
        self.retriever = DocsRetriever()
        if let stored = UserDefaults.standard.string(forKey: Self.activeLearnerKey) {
            self.activeLearnerID = UUID(uuidString: stored)
        }
    }

    // MARK: Derived

    var hasCredentials: Bool { providers.hasAnyCredentials }

    func planner() -> SessionPlanner { SessionPlanner(store: curriculum) }

    /// Build a tutor for this learner, resolving the provider and models.
    func tutor(for learner: Learner) throws -> TutorService {
        let provider = try providers.provider(for: learner)
        return TutorService(
            provider: provider,
            modelID: providers.modelID(for: learner, provider: provider.kind),
            utilityModelID: providers.modelID(for: learner, provider: provider.kind, utility: true)
        )
    }

    /// Record a completed call for the inspector.
    func log(
        purpose: String,
        provider: ProviderKind,
        model: String,
        usage: UsageStats,
        latency: Double,
        error: Error? = nil
    ) {
        let endpoint = (try? providers.provider(for: provider, region: "us-east-1"))?.endpointDescription
            ?? provider.displayName
        requestLog.record(RequestLogEntry(
            purpose: purpose,
            provider: provider,
            endpoint: endpoint,
            model: model,
            usage: usage,
            latencySeconds: latency,
            stopReason: nil,
            errorDescription: error?.localizedDescription
        ))
    }

    // MARK: Curriculum updates

    /// Check for a newer published syllabus and adopt it if there is one.
    ///
    /// Adopting swaps `curriculum` in place. Progress is keyed by concept id,
    /// so a learner keeps their history across an update: concepts that still
    /// exist carry on, new ones appear as available, and rows for removed
    /// concepts sit dormant rather than being deleted.
    @discardableResult
    func checkForCurriculumUpdate() async -> CurriculumUpdate? {
        guard !curriculumCheckInProgress else { return nil }
        curriculumCheckInProgress = true
        curriculumUpdateError = nil
        defer { curriculumCheckInProgress = false }

        do {
            guard let update = try await CurriculumUpdater().checkForUpdate(current: curriculum) else {
                return nil
            }
            if let adopted = CurriculumUpdater.cachedStore() {
                curriculum = adopted
            }
            lastCurriculumUpdate = update
            return update
        } catch let error as LLMError {
            curriculumUpdateError = error.errorDescription
            return nil
        } catch {
            curriculumUpdateError = error.localizedDescription
            return nil
        }
    }

    /// Drop a downloaded syllabus and go back to the bundled one.
    func revertToBundledCurriculum() {
        CurriculumUpdater.clearCache()
        curriculum = .loadFromBundle()
        lastCurriculumUpdate = nil
        curriculumUpdateError = nil
    }

    /// Check for a newer syllabus and refresh the corpus, at most once a day.
    ///
    /// Called on launch. Without this the update machinery works perfectly and
    /// never runs: both halves were behind Settings buttons, so a learner
    /// would keep studying a stale syllabus indefinitely.
    ///
    /// Neither half spends model tokens — a conditional GET for the syllabus
    /// and conditional GETs for documents — so running it unprompted costs
    /// bandwidth, not money.
    func refreshContentIfNeeded(repository: LearningRepository, now: Date = Date()) async {
        let last = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date
        if let last, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        UserDefaults.standard.set(now, forKey: Self.lastRefreshKey)
        await refreshContent(repository: repository)
    }

    /// The refresh itself, unthrottled. Settings calls this directly.
    ///
    /// Order matters: adopt the syllabus first, then sync. A new concept's
    /// sources are not in the corpus until something fetches them, and a
    /// lesson generated in that window is ungrounded — the worst possible
    /// introduction to a concept that just arrived.
    func refreshContent(repository: LearningRepository) async {
        let update = await checkForCurriculumUpdate()
        if let update, !update.newConceptIDs.isEmpty {
            unacknowledgedNewConcepts = update.newConceptIDs
        }
        // force: false, so unchanged documents cost a 304 and only the new
        // concepts' sources are actually downloaded.
        _ = await syncDocs(repository: repository, force: false)
    }

    func acknowledgeNewConcepts() {
        unacknowledgedNewConcepts = []
    }

    // MARK: Docs sync

    /// Refresh the shared document corpus.
    ///
    /// Sequential rather than concurrent on purpose: GitHub's anonymous rate
    /// limit is 60 requests an hour and a burst of parallel fetches burns it
    /// immediately. A sync is a background chore, not something anyone waits on.
    func syncDocs(repository: LearningRepository, force: Bool = false) async -> SyncReport {
        guard !syncInProgress else { return lastSyncReport ?? SyncReport() }
        syncInProgress = true
        defer { syncInProgress = false }

        let service = DocsSyncService(credentials: credentials)
        let plan = DocsSyncService.sourcePlan(for: curriculum)
        var report = SyncReport()

        for entry in plan {
            let existing = repository.snapshot(url: entry.ref.url)
            if !force, let existing, !existing.isStale {
                report.skipped += 1
                continue
            }
            do {
                let validators = existing.map { (etag: $0.etag, lastModified: $0.lastModified) }
                if let document = try await service.fetch(
                    entry.ref, conceptIDs: entry.conceptIDs, existing: validators
                ) {
                    repository.upsert(document)
                    report.fetched += 1
                } else {
                    repository.markFresh(url: entry.ref.url)
                    report.unchanged += 1
                }
            } catch {
                report.failed += 1
                if report.messages.count < 8 {
                    report.messages.append("\(entry.ref.title): \(error.localizedDescription)")
                }
            }
        }

        // Curated sources are authoritative and go first; discovered pages
        // fill the gaps the hand-written list cannot know about, such as
        // documentation published after the syllabus was written.
        if includeDiscoveredSources {
            let discovery = SourceDiscovery()
            let pages = await discovery.discoverAll()
            report.discovered = pages.count

            for entry in discovery.plan(pages: pages, store: curriculum) {
                let existing = repository.snapshot(url: entry.page.url)
                if !force, let existing, !existing.isStale {
                    report.skipped += 1
                    continue
                }
                do {
                    let validators = existing.map { (etag: $0.etag, lastModified: $0.lastModified) }
                    if let document = try await service.fetch(
                        discovered: entry.page, conceptIDs: entry.conceptIDs, existing: validators
                    ) {
                        repository.upsert(document)
                        report.fetched += 1
                    } else {
                        repository.markFresh(url: entry.page.url)
                        report.unchanged += 1
                    }
                } catch {
                    // A discovered page failing is routine — it was a guess, not
                    // a curated choice — so it is counted but not reported.
                    report.failed += 1
                }
            }
        }

        repository.save()
        report.finishedAt = Date()
        lastSyncReport = report
        return report
    }
}

// Injected with `.environment(appEnvironment)` and read with
// `@Environment(AppEnvironment.self)`. The Observable form is used rather than
// a custom EnvironmentKey so there is no main-actor-isolated default value to
// work around, and so view updates track the properties actually read.
