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

    private var commandHeld = false
    private var triggerHeld = false
    private(set) public var isArmed = false

    public init(triggerKey: CGKeyCode = ChordRecognizer.escapeKeyCode) {
        self.triggerKey = triggerKey
    }

    /// Called when the tap is re-enabled after the system disabled it. Key
    /// state observed before the gap is worthless — releases that happened
    /// while we were deaf would leave us armed forever.
    public mutating func reset() {
        commandHeld = false
        triggerHeld = false
        isArmed = false
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
            triggerHeld = true
            // Swallowing only while Command is down is what keeps a bare Escape
            // instantaneous: no withholding, no timer, no re-posting. The cost
            // of this approach is that Escape-then-Command still arms, but the
            // Escape has already reached the app. Harmless, since it emits no
            // character.
            return Decision(action: arm(), swallow: commandHeld || isArmed)

        case .keyUp(let code):
            guard code == triggerKey else { return .ignored }
            triggerHeld = false
            let wasArmed = isArmed
            return Decision(action: disarmIfReleased(), swallow: wasArmed)
        }
    }

    private mutating func arm() -> Action {
        guard commandHeld, triggerHeld, !isArmed else { return .none }
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
