import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Model scorecard")
struct ModelScorecardTests {
    @Test("a realtime factor reads as a multiple")
    func realtimeLabels() {
        #expect(ModelScorecard.speedLabel(speed: 41.3, unit: "realtimeFactor") == "41× realtime")
        // Rounded to whole numbers above 10×: the run-to-run spread is wider
        // than the decimal would suggest, so printing one would be a lie about
        // precision.
        #expect(ModelScorecard.speedLabel(speed: 40.8, unit: "realtimeFactor") == "41× realtime")
        // Below 10× a whole number loses a distinction that matters — 1× and 2×
        // are the difference between usable and not.
        #expect(ModelScorecard.speedLabel(speed: 2.4, unit: "realtimeFactor") == "2.4× realtime")
    }

    @Test("summarizer speed reads as time per meeting")
    func summarizerLabels() {
        #expect(ModelScorecard.speedLabel(speed: 42, unit: "secondsPerMeeting") == "42s per meeting")
        #expect(ModelScorecard.speedLabel(speed: 150, unit: "secondsPerMeeting") == "2 min per meeting")
    }

    @Test("nothing measured means no label rather than a zero")
    func missingSpeed() {
        #expect(ModelScorecard.speedLabel(speed: nil, unit: "realtimeFactor") == nil)
        #expect(ModelScorecard.speedLabel(speed: 0, unit: "realtimeFactor") == nil)
        #expect(ModelScorecard.speedLabel(speed: 12, unit: nil) == nil)
        #expect(ModelScorecard.speedLabel(speed: 12, unit: "furlongsPerFortnight") == nil)
    }

    @Test("a score reads as one of three words")
    func qualityBuckets() {
        func quality(_ value: Double) -> ModelScorecard.Quality {
            ModelScorecard.quality(for: value, role: .dictation)
        }
        #expect(quality(1.0) == .good)
        #expect(quality(0.85) == .good)
        // The boundary cases are the whole point of bucketing: 0.94 and 0.93
        // are one corpus apart and must not read as different.
        #expect(quality(0.943) == quality(0.933))
        #expect(quality(0.849) == .medium)
        #expect(quality(0.70) == .medium)
        #expect(quality(0.699) == .poor)
        // Parakeet 110M, which crashed on 176 of 200 clips. Nothing about that
        // is a tradeoff worth offering.
        #expect(quality(0.252) == .poor)
        #expect(quality(0) == .poor)
    }

    @Test("the word comes from the bundled score for that job")
    func qualityLabels() {
        #expect(ModelScorecard.qualityLabel(for: "parakeet-v3", role: .dictation) == "Good")
        #expect(ModelScorecard.qualityLabel(for: "parakeet-110m", role: .dictation) == "Poor")
        #expect(ModelScorecard.qualityLabel(for: "a-model-that-does-not-exist", role: .dictation) == nil)
    }

    /// The same model, two jobs, two scales. Whisper turbo transcribes
    /// dictation at 0.83 and meetings at 0.48, and the second is not a worse
    /// model — it is a harder measurement, one that also counts who said what.
    /// Judging meetings on the dictation boundaries labelled every model "Poor".
    @Test("a score is graded against the job it was measured on")
    func roleSpecificGrading() {
        let dictation = try? #require(ModelScorecard.entry(for: "whisper-large-v3-turbo", role: .dictation))
        let meeting = try? #require(ModelScorecard.entry(for: "whisper-large-v3-turbo", role: .meeting))
        #expect(dictation!.accuracy > meeting!.accuracy)

        // Both read as usable, because both are, for what they are.
        #expect(ModelScorecard.qualityLabel(for: "whisper-large-v3-turbo", role: .dictation) != "Poor")
        #expect(ModelScorecard.qualityLabel(for: "whisper-large-v3-turbo", role: .meeting) != "Poor")

        // A meeting score that would be excellent dictation is still only a
        // meeting score, and vice versa.
        #expect(ModelScorecard.quality(for: 0.62, role: .meeting) == .good)
        #expect(ModelScorecard.quality(for: 0.62, role: .dictation) == .poor)
    }

    /// Parakeet 110M crashes on short clips and runs on long ones, so it is
    /// genuinely broken for one job and merely poor at the other. One badge per
    /// model could not say that.
    @Test("a model broken at one job is not condemned at the other")
    func brokenAtOneJob() {
        #expect(ModelScorecard.qualityLabel(for: "parakeet-110m", role: .dictation) == "Poor")
        #expect(ModelScorecard.entry(for: "parakeet-110m", role: .meeting)?.accuracy ?? 0 > 0.25)
    }

    /// The picker must survive a model nobody has measured — which is every
    /// model until the harness has been run, and any model added after.
    @Test("an unmeasured model has no entry and no badge")
    func unknownModel() {
        #expect(ModelScorecard.entry(for: "a-model-that-does-not-exist", role: .dictation) == nil)
        #expect(ModelScorecard.speedLabel(for: "a-model-that-does-not-exist", role: .dictation) == nil)
    }

    @Test("the bundled scorecard is present and parses")
    func bundledFileParses() {
        // A copy ships with the library, so failing to find or decode it means
        // the resource declaration in Package.swift has broken.
        #expect(ModelScorecard.isAvailable)
    }

    @Test("every scored model id is one the catalog offers")
    func idsMatchTheCatalog() throws {
        let url = try #require(Bundle.module.url(forResource: "scorecard", withExtension: "json"))
        let file = try JSONDecoder().decode(
            ModelScorecard.File.self, from: Data(contentsOf: url)
        )

        // The harness names models by catalog id. A typo or a rename upstream
        // would silently produce a scorecard whose rows match nothing, and a
        // picker with no badges and no error.
        for id in file.models.keys {
            #expect(ModelCatalog.model(id: id) != nil, "scorecard names unknown model \(id)")
        }
        for (id, roles) in file.models {
            for (role, entry) in roles {
                #expect((0...1).contains(entry.accuracy), "\(id)/\(role) accuracy out of range")
                #expect(ModelScorecard.Role(rawValue: role) != nil, "\(id) has unknown role \(role)")
            }
        }
    }
}
