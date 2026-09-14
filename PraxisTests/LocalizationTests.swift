import Testing
import Foundation
@testable import Praxis

@Suite("Formatting")
struct FormattingTests {

    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let fr = Locale(identifier: "fr_FR")

    @Test("Percentages render as whole numbers")
    func percentBasics() {
        #expect(Format.percent(0.75, locale: us) == "75%")
        #expect(Format.percent(0, locale: us) == "0%")
        #expect(Format.percent(1, locale: us) == "100%")
    }

    @Test("Percentages round rather than truncate")
    func percentRounding() {
        // 0.666 must read as 67%, not 66% — the old Int(x * 100) truncated.
        #expect(Format.percent(0.666, locale: us) == "67%")
        #expect(Format.percent(0.994, locale: us) == "99%")
    }

    @Test("Percent placement follows the locale")
    func percentIsLocalised() {
        let french = Format.percent(0.75, locale: fr)
        #expect(french.contains("75"))
        // French inserts a space before the sign; the point is only that the
        // rendering differs from a hardcoded "75%".
        #expect(french != "75%" || Locale.current.identifier == "fr_FR")
    }

    @Test("Counts use locale grouping separators")
    func countGrouping() {
        #expect(Format.count(1234, locale: us) == "1,234")
        #expect(Format.count(1234, locale: de) == "1.234")
        #expect(Format.count(42, locale: us) == "42")
    }

    @Test("Currency stays USD but formats per locale")
    func currency() {
        let american = Format.usd(1.5, fractionDigits: 3, locale: us)
        #expect(american.contains("1.500"))
        #expect(american.contains("$"))

        // German uses a comma decimal separator; the amount is still dollars.
        let german = Format.usd(1.5, fractionDigits: 3, locale: de)
        #expect(german.contains("1,500"))
    }

    @Test("Durations keep one decimal place")
    func durations() {
        #expect(Format.seconds(2.44, locale: us).contains("2.4"))
        #expect(Format.seconds(10, locale: us).contains("10.0"))
    }

    @Test("Approximate costs are marked with a tilde")
    func approximateCost() {
        #expect(Format.approximateUSD(0.0123, locale: us).hasPrefix("~"))
    }
}

@Suite("Generated content language")
struct LanguageInstructionTests {

    @Test("English gets no language instruction, leaving the prompt unchanged")
    func englishIsUnchanged() {
        #expect(Prompts.languageInstruction(for: Locale(identifier: "en_US")) == nil)
        #expect(Prompts.languageInstruction(for: Locale(identifier: "en_GB")) == nil)
    }

    @Test("Other languages get an instruction naming the language in English")
    func namesTheLanguage() throws {
        let german = try #require(Prompts.languageInstruction(for: Locale(identifier: "de_DE")))
        #expect(german.contains("German"))

        let japanese = try #require(Prompts.languageInstruction(for: Locale(identifier: "ja_JP")))
        #expect(japanese.contains("Japanese"))

        let hindi = try #require(Prompts.languageInstruction(for: Locale(identifier: "hi_IN")))
        #expect(hindi.contains("Hindi"))
    }

    @Test("The instruction carves out identifiers that must not be translated")
    func protectsIdentifiers() throws {
        let instruction = try #require(Prompts.languageInstruction(for: Locale(identifier: "es_ES")))
        // Translating a parameter name or model ID would teach a string that
        // does not exist, so the carve-out is the load-bearing half.
        #expect(instruction.contains("Do NOT translate"))
        for term in ["code", "model identifiers", "URLs"] {
            #expect(instruction.contains(term), "carve-out is missing \(term)")
        }
    }

    @Test("The instruction lands after the cache breakpoint, not in tutorCore")
    func doesNotContaminateTheCachedPrefix() {
        // tutorCore is byte-identical on every request; a language instruction
        // baked into it would reset the prompt cache for every non-English user.
        #expect(!Prompts.tutorCore.contains("Write this lesson in"))

        let learner = Learner(name: "Test", priorKnowledge: "")
        let brief = Prompts.learnerBrief(
            learner, mastery: 0.5, calibration: "Well calibrated.",
            locale: Locale(identifier: "de_DE")
        )
        #expect(brief.contains("German"))
    }

    @Test("Model-facing percentages stay locale-invariant")
    func promptNumbersAreStable() {
        // The learner brief is read by the model, not the user. A German
        // device must not send "50 %" where an American one sends "50%".
        let learner = Learner(name: "Test", priorKnowledge: "")
        for locale in ["en_US", "de_DE", "fr_FR", "ar_EG"].map(Locale.init(identifier:)) {
            let brief = Prompts.learnerBrief(
                learner, mastery: 0.5, calibration: "x", locale: locale
            )
            #expect(brief.contains("Overall curriculum mastery: 50%"))
        }
    }
}

@Suite("Localized UI strings")
struct LocalizedStringTests {

    @Test("Session step titles resolve to non-empty text")
    func sessionStepTitles() {
        for step in SessionStep.allCases {
            #expect(!step.title.isEmpty)
            // The symbol is an SF Symbol identifier and must stay ASCII and
            // untranslated, or the icon silently disappears.
            #expect(step.symbol.allSatisfy { $0.isASCII })
        }
    }

    @Test("Confidence and recall labels resolve")
    func ratingLabels() {
        for level in ConfidenceLevel.allCases { #expect(!level.label.isEmpty) }
        for rating in RecallRating.allCases { #expect(!rating.label.isEmpty) }
    }

    @Test("Every error case produces a message")
    func errorMessages() {
        let errors: [LLMError] = [
            .missingCredentials(.anthropic), .missingCredentials(.bedrock),
            .invalidConfiguration("detail"), .http(status: 500, body: "boom"),
            .rateLimited(retryAfter: 30), .rateLimited(retryAfter: nil),
            .refused(category: "cyber", explanation: nil), .truncated,
            .malformedResponse("detail"), .transport("offline"), .cancelled
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty, "\(error) has no message")
        }
    }

    @Test("Calibration readings resolve across the whole bias range")
    func calibrationReadings() {
        let store = CurriculumStore(curriculum: Curriculum(
            version: 1, generatedNote: "",
            tracks: [Track(id: "t", title: "T", summary: "", order: 1)],
            concepts: []
        ))
        for bias in [-0.9, -0.3, 0.0, 0.15, 0.5, 0.9] {
            let model = MasteryModel(store: store, progress: [
                "x": ReviewState(calibrationBias: bias, calibrationSamples: 3, state: .review)
            ])
            #expect(!model.calibrationDescription.isEmpty)
        }
    }

    @Test("Model picker notes resolve for every catalog entry")
    func modelNotes() {
        for entry in ModelCatalog.anthropic + ModelCatalog.bedrock {
            #expect(!entry.note.isEmpty)
            #expect(ModelCatalog.note(for: entry.id, provider: entry.id.hasPrefix("anthropic.") ? .bedrock : .anthropic) != nil)
        }
        #expect(ModelCatalog.note(for: "no-such-model", provider: .anthropic) == nil)
    }
}
