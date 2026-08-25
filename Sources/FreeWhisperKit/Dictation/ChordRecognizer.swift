import CoreGraphics
import Foundation

/// Recognises a hold-to-talk chord of Command plus one ordinary key.
///
/// This exists because Carbon hotkeys cannot express what we need.
/// `RegisterEventHotKey` delivers its release event when the *non-modifier* key
/// goes up, so it has no way to say "keep recording while Command is still
/// held". Tracking the two keys independently does, and that requires seeing
/// the raw event stream.
///
/// Pure and synchronous on purpose: it is driven from a `CGEventTap` callback,
/// which runs on every keystroke on the system and must never block. All the
/// decisions live here where they can be tested without a keyboard.
public struct ChordRecognizer {
    /// Escape. Types nothing in any context, which is what makes it safe to
    /// swallow: an unrecognised chord costs the user a keystroke that would
    /// have produced no character anyway.
    public static let escapeKeyCode: CGKeyCode = 53

    public enum Event: Equatable {
        case commandDown
        case commandUp
        case keyDown(CGKeyCode)
        case keyUp(CGKeyCode)
    }

    public enum Action: Equatable {
        case none
        case start
        case stop
        /// Abandon the dictation that is already running. Only ever produced for
        /// a bare press of the trigger key while one is — see `handle`.
        case cancel
    }

    public struct Decision: Equatable {
        public let action: Action
        /// Whether the event should be withheld from the app underneath.
        public let swallow: Bool

        public init(action: Action, swallow: Bool) {
            self.action = action
            self.swallow = swallow
        }
    }

    public let triggerKey: CGKeyCode

    /// Whether a dictation is running right now, and is therefore cancellable.
    ///
    /// An input refreshed by the caller before every event rather than state
    /// this type owns — which is why `reset()` deliberately leaves it alone. It
    /// has to be a stored property instead of a parameter because the caller is
    /// a `CGEventTap` callback that must answer synchronously, with no chance to
    /// hop to the main actor and ask.
    public var dictationIsActive = false

    /// Whether the chord may start a dictation at all.
    ///
    /// False when the tap is up purely so Escape can cancel: the user turned the
    /// chord off, and both starting a dictation from ⌘⎋ and swallowing their ⌘⎋
    /// would be exactly what they asked us not to do.
    public var armingEnabled = true

    private var commandHeld = false
    private var triggerHeld = false
    private(set) public var isArmed = false
    /// Set when we withheld a trigger key-down as a cancel, so its key-up can be
    /// withheld to match.
    private var swallowedCancel = false

    public init(triggerKey: CGKeyCode = ChordRecognizer.escapeKeyCode) {
        self.triggerKey = triggerKey
    }

    /// Called when the tap is re-enabled after the system disabled it. Key
    /// state observed before the gap is worthless — releases that happened
    /// while we were deaf would leave us armed forever.
    ///
    /// `dictationIsActive` is untouched on purpose: it is an input describing
    /// the world outside this type, and a dictation does not stop running just
    /// because the tap hiccupped. Clearing the key state, though, is what makes
    /// the next Escape read as *bare* again — which turns the recovery path into
    /// a working cancel while the controller is still listening.
    public mutating func reset() {
        commandHeld = false
        triggerHeld = false
        isArmed = false
        swallowedCancel = false
    }

    public mutating func handle(_ event: Event) -> Decision {
        switch event {
        case .commandDown:
            commandHeld = true
            // Never swallow a modifier. Suppressing Command would break every
            // shortcut on the system, including the paste this feature ends in.
            return Decision(action: arm(), swallow: false)

        case .commandUp:
            commandHeld = false
            return Decision(action: disarmIfReleased(), swallow: false)

        case .keyDown(let code):
            guard code == triggerKey else { return .ignored }
            let wasHeld = triggerHeld
            triggerHeld = true

            // A bare trigger press while a dictation is running means "stop".
            // Every clause here is load-bearing:
            //
            //   dictationIsActive — swallowing a bare Escape when there is
            //     nothing to cancel would break Escape in every app on this Mac.
            //     This clause is the only thing standing between us and that.
            //   !isArmed — while the chord is live this *is* the chord's own
            //     key, and cancelling on it would abort the dictation the user
            //     is still holding the keys down for.
            //   !commandHeld — ⌘⎋ means "dictate". Leave it meaning that.
            //   !wasHeld — auto-repeat always arrives with the key already held,
            //     a deliberate press never does. Without this the default
            //     trigger would cancel itself on its own first repeat, about
            //     half a second after starting.
            if dictationIsActive, !isArmed, !commandHeld, !wasHeld {
                swallowedCancel = true
                return Decision(action: .cancel, swallow: true)
            }

            // Swallowing only while Command is down is what keeps a bare Escape
            // instantaneous: no withholding, no timer, no re-posting. The cost
            // of this approach is that Escape-then-Command still arms, but the
            // Escape has already reached the app. Harmless, since it emits no
            // character.
            //
            // `swallowedCancel` keeps the auto-repeats of a cancel press
            // withheld too. Without it we would hand the app underneath a run of
            // repeats belonging to a key-down it never saw.
            return Decision(
                action: arm(),
                swallow: swallowedCancel || (armingEnabled && (commandHeld || isArmed))
            )

        case .keyUp(let code):
            guard code == triggerKey else { return .ignored }
            triggerHeld = false
            let wasArmed = isArmed
            // Withhold the release of a key-down we withheld. A lone key-up is
            // harmless in most apps, but handing one half of a keystroke to an
            // app is the kind of thing that surfaces in one obscure editor a
            // year from now.
            let matchingCancel = swallowedCancel
            swallowedCancel = false
            return Decision(action: disarmIfReleased(), swallow: wasArmed || matchingCancel)
        }
    }

    private mutating func arm() -> Action {
        guard armingEnabled, commandHeld, triggerHeld, !isArmed else { return .none }
        isArmed = true
        return .start
    }

    /// Both keys have to be up. Releasing one and holding the other keeps the
    /// recording running, so a long dictation does not depend on holding an
    /// awkward two-key shape perfectly still.
    private mutating func disarmIfReleased() -> Action {
        guard isArmed, !commandHeld, !triggerHeld else { return .none }
        isArmed = false
        return .stop
    }
}

extension ChordRecognizer.Decision {
    static let ignored = Self(action: .none, swallow: false)
}
