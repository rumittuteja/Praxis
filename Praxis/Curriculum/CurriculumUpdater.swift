import Foundation

/// Outcome of a curriculum update check, for display in Settings.
struct CurriculumUpdate: Sendable, Equatable {
    var previousVersion: Int
    var newVersion: Int
    var conceptCount: Int
    var newConceptIDs: [String]
    var removedConceptIDs: [String]
    var fetchedAt: Date
}

/// Fetches a newer syllabus without shipping an app build.
///
/// The bundled `curriculum.json` is the floor, never removed. This checks a
/// remote copy and adopts it only if it is **both** newer and structurally
/// valid — a broken graph would silently lock concepts forever, so validation
/// runs before adoption rather than at read time.
///
/// This is what turns "add a concept" from an App Store release into a commit.
struct CurriculumUpdater: Sendable {

    /// The syllabus in the repository's default branch. Raw content, so no API
    /// token and no rate limit worth worrying about.
    static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/rumittuteja/Praxis/main/Praxis/Curriculum/Resources/curriculum.json"
    )!

    var remoteURL: URL = CurriculumUpdater.defaultRemoteURL

    private static let etagKey = "praxis.curriculum.etag"
    private static let versionKey = "praxis.curriculum.cachedVersion"

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    init(remoteURL: URL = CurriculumUpdater.defaultRemoteURL, defaults: UserDefaults = .standard) {
        self.remoteURL = remoteURL
        self.defaults = defaults
    }

    // MARK: Cache location

    /// Application Support, not Caches: the OS may evict Caches under pressure,
    /// and silently reverting a learner's syllabus mid-course is worse than
    /// using a few kilobytes of backed-up storage.
    static var cacheURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return directory.appendingPathComponent("curriculum.json")
    }

    /// The cached syllabus, if one is present and still parses. A corrupt cache
    /// returns nil so the caller falls back to the bundle.
    static func cachedStore() -> CurriculumStore? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let store = try? CurriculumStore(data: data),
              store.integrityProblems().isEmpty
        else { return nil }
        return store
    }

    static func clearCache() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: etagKey)
        UserDefaults.standard.removeObject(forKey: versionKey)
    }

    // MARK: Checking

    /// Check for a newer syllabus. Returns nil when there is nothing to adopt —
    /// unchanged, older, or same version.
    ///
    /// - Throws: only on a network or parse failure. A remote syllabus that
    ///   fails validation throws too, because silently ignoring a broken
    ///   publish is how you ship a curriculum nobody can progress through.
    @discardableResult
    func checkForUpdate(current: CurriculumStore) async throws -> CurriculumUpdate? {
        var request = URLRequest(url: remoteURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = defaults.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("Curriculum response was not HTTP.")
        }
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: "Could not fetch the curriculum.")
        }

        let candidate: CurriculumStore
        do {
            candidate = try CurriculumStore(data: data)
        } catch {
            throw LLMError.malformedResponse("The published curriculum could not be parsed: \(error)")
        }

        // Validate before adopting, never after.
        let problems = candidate.integrityProblems()
        guard problems.isEmpty else {
            throw LLMError.malformedResponse(
                "The published curriculum failed validation and was not applied. "
                + problems.prefix(3).joined(separator: "; ")
            )
        }

        let currentVersion = current.curriculum.version
        guard candidate.curriculum.version > currentVersion else {
            // Record the ETag anyway so an unchanged file is a cheap 304 next time.
            storeETag(from: http)
            return nil
        }

        guard let cacheURL = Self.cacheURL else {
            throw LLMError.invalidConfiguration("No writable location for the curriculum cache.")
        }
        try data.write(to: cacheURL, options: .atomic)
        storeETag(from: http)
        defaults.set(candidate.curriculum.version, forKey: Self.versionKey)

        let currentIDs = Set(current.allConcepts.map(\.id))
        let candidateIDs = Set(candidate.allConcepts.map(\.id))

        return CurriculumUpdate(
            previousVersion: currentVersion,
            newVersion: candidate.curriculum.version,
            conceptCount: candidate.allConcepts.count,
            newConceptIDs: candidateIDs.subtracting(currentIDs).sorted(),
            // Progress rows for removed concepts are left alone rather than
            // deleted: a concept pulled in one publish and restored in the next
            // should not cost the learner their history.
            removedConceptIDs: currentIDs.subtracting(candidateIDs).sorted(),
            fetchedAt: Date()
        )
    }

    private func storeETag(from response: HTTPURLResponse) {
        if let etag = response.value(forHTTPHeaderField: "Etag") {
            defaults.set(etag, forKey: Self.etagKey)
        }
    }
}
