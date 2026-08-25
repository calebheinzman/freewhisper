import Testing

@testable import FreeWhisperKit

@Suite("Dictation activity")
struct DictationActivityTests {
    @Test("nothing is running to begin with")
    func startsIdle() {
        let activity = DictationActivity()
        #expect(!activity.isRunning)
        #expect(activity.claimCancel() == nil)
    }

    @Test("each run gets its own generation")
    func generationsIncrease() {
        let activity = DictationActivity()
        let first = activity.begin()
        let second = activity.begin()

        #expect(second > first)
        #expect(activity.isRunning)
    }

    @Test("claiming a cancel takes the run out of play")
    func claimStopsTheRun() {
        let activity = DictationActivity()
        let generation = activity.begin()

        #expect(activity.claimCancel() == generation)
        // The gate every transcription exit checks before it pastes.
        #expect(!activity.isRunning(generation))
        #expect(!activity.isRunning)
    }

    /// Escape claims the cancel inside the event tap and the HUD's button claims
    /// it on the main actor. Both paths can run for one cancel, and the second
    /// must be a no-op rather than an error.
    @Test("claiming twice is harmless")
    func claimIsIdempotent() {
        let activity = DictationActivity()
        _ = activity.begin()

        #expect(activity.claimCancel() != nil)
        #expect(activity.claimCancel() == nil)
    }

    /// The stale-completion property: a transcription that finishes long after
    /// the user gave up on it must not tear down the dictation they started
    /// since.
    @Test("ending a run does not end the one that replaced it")
    func endOnlyEndsItsOwnGeneration() {
        let activity = DictationActivity()
        let first = activity.begin()
        let second = activity.begin()

        activity.end(first)

        #expect(activity.isRunning(second))
        #expect(!activity.isRunning(first))
    }

    @Test("ending the current run leaves nothing running")
    func endClearsTheCurrentRun() {
        let activity = DictationActivity()
        let generation = activity.begin()
        activity.end(generation)

        #expect(!activity.isRunning)
    }

    /// A cancelled run's generation is never reissued, so the transcription it
    /// belonged to stays locked out even once the next dictation is under way.
    @Test("a cancelled run stays cancelled after a new one starts")
    func cancelledRunNeverComesBack() {
        let activity = DictationActivity()
        let cancelled = activity.begin()
        activity.claimCancel()

        let fresh = activity.begin()

        #expect(!activity.isRunning(cancelled))
        #expect(activity.isRunning(fresh))
    }
}
