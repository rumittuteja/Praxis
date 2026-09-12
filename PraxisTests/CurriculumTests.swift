import Testing
import Foundation
@testable import Praxis

/// The curriculum is a hand-authored graph of 100+ nodes. A dangling
/// prerequisite or a cycle would silently lock concepts forever with no
/// runtime error, so the graph is validated as a test rather than trusted.
@Suite("Curriculum")
struct CurriculumTests {

    private func loadStore() throws -> CurriculumStore {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(
            bundle.url(forResource: "curriculum", withExtension: "json")
                ?? Bundle.main.url(forResource: "curriculum", withExtension: "json"),
            "curriculum.json must be in the test bundle resources"
        )
        return try CurriculumStore(data: Data(contentsOf: url))
    }

    @Test("The bundled curriculum parses")
    func parses() throws {
        let store = try loadStore()
        #expect(store.allConcepts.count > 80)
        #expect(store.tracks.count == 7)
    }

    @Test("The prerequisite graph has no dangling edges, cycles, or bad tiers")
    func integrity() throws {
        let store = try loadStore()
        let problems = store.integrityProblems()
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("Every concept is reachable from a prerequisite-free root")
    func reachable() throws {
        let store = try loadStore()
        var satisfied = Set<String>()
        var changed = true

        // Repeatedly unlock whatever is now available, as a learner would.
        while changed {
            changed = false
            for concept in store.unlockedConcepts(given: satisfied)
            where !satisfied.contains(concept.id) {
                satisfied.insert(concept.id)
                changed = true
            }
        }
        let unreachable = Set(store.allConcepts.map(\.id)).subtracting(satisfied)
        #expect(unreachable.isEmpty, "unreachable: \(unreachable.sorted())")
    }

    @Test("Each track has at least one entry point a learner can start on")
    func everyTrackIsEnterable() throws {
        let store = try loadStore()
        for track in store.tracks {
            let concepts = store.concepts(inTrack: track.id)
            #expect(!concepts.isEmpty, "track \(track.id) has no concepts")
        }
    }

    @Test("Prerequisites never point at a harder concept")
    func prerequisiteTiersAreNotInverted() throws {
        let store = try loadStore()
        for concept in store.allConcepts {
            for id in concept.prerequisites {
                guard let prerequisite = store.concept(id) else { continue }
                #expect(
                    prerequisite.tier <= concept.tier,
                    "\(concept.id) (tier \(concept.tier)) requires \(id) (tier \(prerequisite.tier))"
                )
            }
        }
    }

    @Test("Every concept carries objectives, key ideas, and a source")
    func contentCompleteness() throws {
        let store = try loadStore()
        for concept in store.allConcepts {
            #expect(!concept.objectives.isEmpty, "\(concept.id) has no objectives")
            #expect(!concept.keyIdeas.isEmpty, "\(concept.id) has no key ideas")
            #expect(!concept.misconceptions.isEmpty, "\(concept.id) has no misconceptions")
            #expect(!concept.sources.isEmpty, "\(concept.id) has no sources")
            #expect(!concept.practiceKinds.isEmpty, "\(concept.id) has no practice kinds")
        }
    }

    @Test("Every source URL is well formed and https")
    func sourceURLs() throws {
        let store = try loadStore()
        for concept in store.allConcepts {
            for source in concept.sources {
                let url = URL(string: source.url)
                #expect(url != nil, "\(concept.id): unparseable \(source.url)")
                #expect(source.url.hasPrefix("https://"), "\(concept.id): \(source.url) is not https")
            }
        }
    }

    @Test("Missing prerequisites are reported for a locked concept")
    func missingPrerequisites() throws {
        let store = try loadStore()
        let gated = try #require(store.allConcepts.first { !$0.prerequisites.isEmpty })
        let missing = store.missingPrerequisites(for: gated, given: [])
        #expect(missing.count == gated.prerequisites.count)
    }

    @Test("Integrity checking catches a deliberately broken graph")
    func detectsBrokenGraph() {
        let broken = Curriculum(
            version: 1,
            generatedNote: "",
            tracks: [Track(id: "t", title: "T", summary: "", order: 1)],
            concepts: [
                Concept(id: "a", trackID: "t", title: "A", tier: 1, summary: "s",
                        prerequisites: ["nope"], objectives: ["o"], keyIdeas: ["k"],
                        misconceptions: ["m"], practiceKinds: [.explanation], sources: [],
                        estimatedMinutes: 5, requiresAWSAccount: nil)
            ]
        )
        let problems = CurriculumStore(curriculum: broken).integrityProblems()
        #expect(problems.contains { $0.contains("nope") })
    }

    @Test("Integrity checking catches a prerequisite cycle")
    func detectsCycle() {
        func concept(_ id: String, requires: [String]) -> Concept {
            Concept(id: id, trackID: "t", title: id, tier: 1, summary: "s",
                    prerequisites: requires, objectives: ["o"], keyIdeas: ["k"],
                    misconceptions: ["m"], practiceKinds: [.explanation], sources: [],
                    estimatedMinutes: 5, requiresAWSAccount: nil)
        }
        let cyclic = Curriculum(
            version: 1, generatedNote: "",
            tracks: [Track(id: "t", title: "T", summary: "", order: 1)],
            concepts: [concept("a", requires: ["b"]), concept("b", requires: ["a"])]
        )
        let problems = CurriculumStore(curriculum: cyclic).integrityProblems()
        #expect(problems.contains { $0.lowercased().contains("cycle") })
    }
}

/// Anchor for locating the test bundle.
private final class BundleToken {}
