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

    /// The picker must survive a model nobody has measured — which is every
    /// model until the harness has been run, and any model added after.
    @Test("an unmeasured model has no entry and no badge")
    func unknownModel() {
        #expect(ModelScorecard.entry(for: "a-model-that-does-not-exist") == nil)
        #expect(ModelScorecard.speedLabel(for: "a-model-that-does-not-exist") == nil)
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
        for (id, entry) in file.models {
            #expect((0...1).contains(entry.accuracy), "\(id) accuracy out of range")
        }
    }
}
