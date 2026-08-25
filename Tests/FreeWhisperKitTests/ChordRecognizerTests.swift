import CoreGraphics
import Testing

@testable import FreeWhisperKit

@Suite("Dictation chord")
struct ChordRecognizerTests {
    private let esc = ChordRecognizer.escapeKeyCode
    private let keyA: CGKeyCode = 0

    /// Drives a sequence and returns every action it produced, which is how
    /// most of these assertions read most naturally.
    private func actions(
        _ events: [ChordRecognizer.Event],
        into recognizer: inout ChordRecognizer
    ) -> [ChordRecognizer.Action] {
        events.map { recognizer.handle($0).action }.filter { $0 != .none }
    }

    @Test("command then escape starts dictation")
    func armsInTheNaturalOrder() {
        var recognizer = ChordRecognizer()
        let result = actions([.commandDown, .keyDown(esc)], into: &recognizer)
        #expect(result == [.start])
        #expect(recognizer.isArmed)
    }

    @Test("escape then command also starts it")
    func armsInEitherOrder() {
        var recognizer = ChordRecognizer()
        let result = actions([.keyDown(esc), .commandDown], into: &recognizer)
        #expect(result == [.start])
    }

    /// The whole point of choosing Escape: it must stay instantly usable on its
    /// own, with no withholding and no delay.
    @Test("escape alone neither arms nor is swallowed")
    func bareEscapeIsUntouched() {
        var recognizer = ChordRecognizer()
        let down = recognizer.handle(.keyDown(esc))
        let up = recognizer.handle(.keyUp(esc))

        #expect(down == ChordRecognizer.Decision(action: .none, swallow: false))
        #expect(up == ChordRecognizer.Decision(action: .none, swallow: false))
        #expect(!recognizer.isArmed)
    }

    @Test("command alone does not arm")
    func commandAloneDoesNothing() {
        var recognizer = ChordRecognizer()
        #expect(actions([.commandDown, .commandUp], into: &recognizer).isEmpty)
    }

    @Test("other keys are ignored entirely")
    func otherKeysAreIgnored() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)
        let decision = recognizer.handle(.keyDown(keyA))

        // Command-A has to keep selecting all.
        #expect(decision == ChordRecognizer.Decision(action: .none, swallow: false))
        #expect(!recognizer.isArmed)
    }

    /// The release rule the user asked for: holding either key keeps it going,
    /// so a long dictation doesn't depend on holding an awkward shape still.
    @Test("releasing escape while command is held keeps recording")
    func escapeReleaseAloneKeepsGoing() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)
        _ = recognizer.handle(.keyDown(esc))

        #expect(recognizer.handle(.keyUp(esc)).action == .none)
        #expect(recognizer.isArmed)
        #expect(recognizer.handle(.commandUp).action == .stop)
        #expect(!recognizer.isArmed)
    }

    @Test("releasing command while escape is held keeps recording")
    func commandReleaseAloneKeepsGoing() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)
        _ = recognizer.handle(.keyDown(esc))

        #expect(recognizer.handle(.commandUp).action == .none)
        #expect(recognizer.isArmed)
        #expect(recognizer.handle(.keyUp(esc)).action == .stop)
    }

    @Test("the trigger is swallowed while the chord is live")
    func triggerIsSwallowedWhileLive() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)

        #expect(recognizer.handle(.keyDown(esc)).swallow)
        // Auto-repeat arrives as further key-downs and must not leak either.
        #expect(recognizer.handle(.keyDown(esc)).swallow)
        #expect(recognizer.handle(.keyUp(esc)).swallow)
    }

    /// Suppressing Command would break every shortcut on the system, including
    /// the paste this feature ends in.
    @Test("modifier events are never swallowed")
    func modifiersAreNeverSwallowed() {
        var recognizer = ChordRecognizer()
        #expect(!recognizer.handle(.commandDown).swallow)
        _ = recognizer.handle(.keyDown(esc))
        #expect(!recognizer.handle(.commandUp).swallow)
    }

    @Test("a second chord can be armed after the first finishes")
    func rearmsAfterRelease() {
        var recognizer = ChordRecognizer()
        let result = actions([
            .commandDown, .keyDown(esc), .keyUp(esc), .commandUp,
            .commandDown, .keyDown(esc), .keyUp(esc), .commandUp,
        ], into: &recognizer)
        #expect(result == [.start, .stop, .start, .stop])
    }

    @Test("arming twice does not restart an in-flight recording")
    func doesNotDoubleStart() {
        var recognizer = ChordRecognizer()
        let result = actions([.commandDown, .keyDown(esc), .commandDown, .keyDown(esc)], into: &recognizer)
        #expect(result == [.start])
    }

    /// The system disables a tap that stalls. Key state observed before the gap
    /// is worthless: a release during the gap would otherwise leave us armed
    /// forever with the microphone open.
    @Test("reset clears state after the tap is re-enabled")
    func resetClearsState() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)
        _ = recognizer.handle(.keyDown(esc))
        #expect(recognizer.isArmed)

        recognizer.reset()
        #expect(!recognizer.isArmed)

        // And a bare Escape is untouched again, rather than being swallowed on
        // the strength of a Command we think is still down.
        #expect(!recognizer.handle(.keyDown(esc)).swallow)
    }

    @Test("the trigger key is configurable")
    func triggerIsConfigurable() {
        var recognizer = ChordRecognizer(triggerKey: keyA)
        #expect(actions([.commandDown, .keyDown(keyA)], into: &recognizer) == [.start])
    }

    // MARK: Cancelling

    /// The most important test here. The chord's trigger key *is* Escape, so
    /// during a hold the physical key is down and auto-repeating — and every
    /// repeat arrives as another key-down indistinguishable from a deliberate
    /// press. Cancel on one of those and the default trigger aborts the
    /// dictation it just started, about half a second in.
    @Test("auto-repeat during a hold never cancels the dictation it started")
    func autoRepeatDoesNotCancelItsOwnChord() {
        var recognizer = ChordRecognizer()
        _ = recognizer.handle(.commandDown)
        #expect(recognizer.handle(.keyDown(esc)).action == .start)

        // The controller is now listening, so the monitor starts reporting it.
        recognizer.dictationIsActive = true

        #expect(recognizer.handle(.keyDown(esc)).action == .none)
        #expect(recognizer.handle(.keyDown(esc)).action == .none)
        #expect(recognizer.isArmed)
    }

    @Test("a bare escape cancels a running dictation, and is swallowed")
    func bareEscapeCancels() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = true

        #expect(recognizer.handle(.keyDown(esc)) == ChordRecognizer.Decision(action: .cancel, swallow: true))
    }

    /// Half a keystroke is not a thing to hand an app.
    @Test("the release after a cancel is swallowed too")
    func cancelReleaseIsSwallowed() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = true

        _ = recognizer.handle(.keyDown(esc))
        #expect(recognizer.handle(.keyUp(esc)).swallow)
        // And the next one, with nothing running, is untouched again.
        recognizer.dictationIsActive = false
        #expect(!recognizer.handle(.keyDown(esc)).swallow)
        #expect(!recognizer.handle(.keyUp(esc)).swallow)
    }

    /// Holding Escape down to cancel repeats it. The app underneath must not
    /// receive a run of repeats for a key-down it never saw.
    @Test("auto-repeats of a cancel press are swallowed too")
    func cancelAutoRepeatIsSwallowed() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = true

        #expect(recognizer.handle(.keyDown(esc)).action == .cancel)
        // The dictation is over now, so the monitor stops reporting one — but
        // these repeats still belong to the press we withheld.
        recognizer.dictationIsActive = false
        #expect(recognizer.handle(.keyDown(esc)).swallow)
        #expect(recognizer.handle(.keyDown(esc)).swallow)
        #expect(recognizer.handle(.keyUp(esc)).swallow)

        // And the next press, well after the fact, is untouched.
        #expect(!recognizer.handle(.keyDown(esc)).swallow)
    }

    /// Property #1 of the whole feature: Escape is only ever withheld when it
    /// actually cancels something. `bareEscapeIsUntouched` covers the default
    /// case; this covers it stated explicitly.
    @Test("escape is never swallowed when no dictation is running")
    func escapeUntouchedWithNothingRunning() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = false

        #expect(recognizer.handle(.keyDown(esc)) == ChordRecognizer.Decision(action: .none, swallow: false))
        #expect(recognizer.handle(.keyUp(esc)) == ChordRecognizer.Decision(action: .none, swallow: false))
    }

    /// ⌘⎋ keeps meaning "dictate" even while one is already running. The
    /// controller's own busy guard is what makes it a no-op.
    @Test("command-escape while a dictation runs still means dictate")
    func chordIsNotACancel() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = true

        #expect(actions([.commandDown, .keyDown(esc)], into: &recognizer) == [.start])
    }

    @Test("with arming off the chord neither starts nor is swallowed")
    func armingOffLeavesTheChordAlone() {
        var recognizer = ChordRecognizer()
        recognizer.armingEnabled = false

        #expect(recognizer.handle(.commandDown).action == .none)
        #expect(recognizer.handle(.keyDown(esc)) == ChordRecognizer.Decision(action: .none, swallow: false))
        #expect(!recognizer.isArmed)
        #expect(!recognizer.handle(.keyUp(esc)).swallow)
    }

    /// The cancel-only tap: the user turned the chord off, so ⌘⎋ is theirs
    /// again, but Escape must still stop a dictation started some other way.
    @Test("escape still cancels with arming off")
    func cancelWorksWithArmingOff() {
        var recognizer = ChordRecognizer()
        recognizer.armingEnabled = false
        recognizer.dictationIsActive = true

        #expect(recognizer.handle(.keyDown(esc)) == ChordRecognizer.Decision(action: .cancel, swallow: true))
    }

    /// A dictation does not stop running because the tap hiccupped, so the
    /// liveness input survives — but the key state does not, which is what makes
    /// the next Escape read as bare and therefore cancel.
    @Test("reset clears key state but not the liveness input")
    func resetLeavesTheInputAlone() {
        var recognizer = ChordRecognizer()
        recognizer.dictationIsActive = true
        _ = recognizer.handle(.commandDown)
        _ = recognizer.handle(.keyDown(esc))
        #expect(recognizer.isArmed)

        recognizer.reset()

        #expect(recognizer.dictationIsActive)
        #expect(recognizer.handle(.keyDown(esc)).action == .cancel)
    }
}
