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

    let curriculum: CurriculumStore
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

    private static let activeLearnerKey = "praxis.activeLearnerID"

    init(
        curriculum: CurriculumStore = .loadFromBundle(),
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
