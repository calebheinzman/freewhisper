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
}
