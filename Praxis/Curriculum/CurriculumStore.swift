import Foundation

/// Loads the syllabus and answers structural questions about it.
///
/// Pure and synchronous: the curriculum is a bundled resource, so there's no
/// reason for this to be async or failable at call sites.
struct CurriculumStore: Sendable {

    let curriculum: Curriculum
    private let conceptsByID: [String: Concept]
    private let conceptsByTrack: [String: [Concept]]

    static let resourceName = "curriculum"

    /// Loads from the app bundle. Traps on failure by design — a missing or
    /// malformed curriculum is a build error, not a runtime condition to
    /// degrade around, and failing loudly in development beats an empty app.
    static func loadFromBundle(_ bundle: Bundle = .main) -> CurriculumStore {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            fatalError("curriculum.json is missing from the app bundle.")
        }
        do {
            let data = try Data(contentsOf: url)
            return try CurriculumStore(data: data)
        } catch {
            fatalError("curriculum.json could not be parsed: \(error)")
        }
    }

    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(Curriculum.self, from: data)
        self.init(curriculum: decoded)
    }

    init(curriculum: Curriculum) {
        self.curriculum = curriculum
        self.conceptsByID = Dictionary(
            curriculum.concepts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.conceptsByTrack = Dictionary(grouping: curriculum.concepts, by: \.trackID)
    }

    // MARK: Lookup

    var allConcepts: [Concept] { curriculum.concepts }
    var tracks: [Track] { curriculum.tracks.sorted { $0.order < $1.order } }

    func concept(_ id: String) -> Concept? { conceptsByID[id] }

    func concepts(inTrack trackID: String) -> [Concept] {
        (conceptsByTrack[trackID] ?? []).sorted { lhs, rhs in
            lhs.tier == rhs.tier ? lhs.id < rhs.id : lhs.tier < rhs.tier
        }
    }

    func track(_ id: String) -> Track? { curriculum.tracks.first { $0.id == id } }

    func trackTitle(_ id: String) -> String { track(id)?.title ?? id }

    // MARK: Structure

    /// Concepts whose prerequisites are all satisfied, given a set of concept
    /// IDs the learner has reached `.review` or better on.
    func unlockedConcepts(given satisfied: Set<String>) -> [Concept] {
        curriculum.concepts.filter { concept in
            concept.prerequisites.allSatisfy { satisfied.contains($0) }
        }
    }

    func prerequisitesMet(for concept: Concept, given satisfied: Set<String>) -> Bool {
        concept.prerequisites.allSatisfy { satisfied.contains($0) }
    }

    /// Prerequisites still outstanding, for the "locked" explanation in the UI.
    func missingPrerequisites(for concept: Concept, given satisfied: Set<String>) -> [Concept] {
        concept.prerequisites
            .filter { !satisfied.contains($0) }
            .compactMap { conceptsByID[$0] }
    }

    /// Validates the graph. Run in tests and once at launch in debug builds:
    /// a dangling prerequisite ID would silently lock a concept forever.
    func integrityProblems() -> [String] {
        var problems: [String] = []
        let trackIDs = Set(curriculum.tracks.map(\.id))
        var seenIDs = Set<String>()

        for concept in curriculum.concepts {
            if !seenIDs.insert(concept.id).inserted {
                problems.append("Duplicate concept id: \(concept.id)")
            }
            if !trackIDs.contains(concept.trackID) {
                problems.append("\(concept.id) references unknown track \(concept.trackID)")
            }
            if !(1...5).contains(concept.tier) {
                problems.append("\(concept.id) has tier \(concept.tier), expected 1...5")
            }
            for prerequisite in concept.prerequisites where conceptsByID[prerequisite] == nil {
                problems.append("\(concept.id) requires unknown concept \(prerequisite)")
            }
            if concept.objectives.isEmpty {
                problems.append("\(concept.id) has no objectives")
            }
        }
        problems.append(contentsOf: cycleProblems())
        return problems
    }

    /// Depth-first cycle detection over the prerequisite graph.
    private func cycleProblems() -> [String] {
        var problems: [String] = []
        var visiting = Set<String>()
        var done = Set<String>()

        func visit(_ id: String, path: [String]) {
            if done.contains(id) { return }
            if visiting.contains(id) {
                problems.append("Prerequisite cycle: \((path + [id]).joined(separator: " -> "))")
                return
            }
            visiting.insert(id)
            for prerequisite in conceptsByID[id]?.prerequisites ?? [] {
                visit(prerequisite, path: path + [id])
            }
            visiting.remove(id)
            done.insert(id)
        }

        for concept in curriculum.concepts { visit(concept.id, path: []) }
        return problems
    }
}
