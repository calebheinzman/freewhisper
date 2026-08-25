import AppKit
import FreeWhisperKit

/// Watches the system keyboard for the dictation chord.
///
/// A `CGEventTap` rather than a Carbon hotkey, because the chord's release rule
/// (keep going while *either* key is held) needs independent visibility of the
/// modifier and the key — see `ChordRecognizer`. The tap needs Accessibility,
/// which dictation already requires in order to type its result.
///
/// The callback runs on the main run loop for every keystroke on the system, so
/// it does the minimum possible work: translate the event, ask the recognizer,
/// and hand any resulting action to the main actor asynchronously.
final class ChordMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var recognizer = ChordRecognizer()

    /// Callbacks are delivered on the main actor.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    /// False when the tap could not be created, which in practice means
    /// Accessibility has not been granted. The UI reads this so a dead chord is
    /// visible rather than silent.
    var isActive: Bool { tap != nil }

    var isArmed: Bool { recognizer.isArmed }

    func start() {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ChordMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.dictation.error("could not create the chord event tap — Accessibility is probably not granted")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        Log.dictation.notice("chord monitor active: hold command-escape to dictate")
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        recognizer.reset()
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long to respond, or when the
        // user's input is taken over. Silently dying is exactly the failure this
        // whole feature has already been bitten by, so re-arm loudly. Key state
        // observed before the gap is worthless — releases may have been missed.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.dictation.notice("chord event tap was disabled (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            recognizer.reset()
            return Unmanaged.passUnretained(event)
        }

        guard let chordEvent = translate(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        let decision = recognizer.handle(chordEvent)

        switch decision.action {
        case .start:
            Log.dictation.notice("chord armed")
            Task { @MainActor in self.onStart?() }
        case .stop:
            Log.dictation.notice("chord released")
            Task { @MainActor in self.onStop?() }
        case .none:
            break
        }

        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func translate(type: CGEventType, event: CGEvent) -> ChordRecognizer.Event? {
        switch type {
        case .flagsChanged:
            // flagsChanged fires for every modifier; we only care whether
            // Command's state differs from what we last recorded, and the
            // recognizer is idempotent about repeats.
            return event.flags.contains(.maskCommand) ? .commandDown : .commandUp
        case .keyDown:
            return .keyDown(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
        case .keyUp:
            return .keyUp(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            return nil
        }
    }
}
