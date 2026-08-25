import Foundation

/// Which dictation, if any, the user is currently waiting on.
///
/// A generation counter rather than a bool because the two things that ask "is
/// this still wanted?" are racing different clocks: a cancel can land while a
/// transcription is finishing, and a *new* dictation can start before a stale
/// one gets around to answering. Equality against a generation answers both,
/// where a bare `isCancelled` flag would let a stale run clobber the run that
/// replaced it — and a stale dictation does not merely mislabel something, it
/// types into whatever app the user is now in.
///
/// Lock-guarded and deliberately not main-actor-isolated. Its other reader is a
/// `CGEventTap` callback, which fires on every keystroke on the system and has
/// to decide whether to withhold the key *synchronously*, with no chance to
/// await the controller that owns the dictation state.
public final class DictationActivity: @unchecked Sendable {
    private let lock = NSLock()
    /// The generation the user is waiting on; zero means nothing is running.
    private var current: UInt64 = 0
    private var issued: UInt64 = 0

    public init() {}

    public var isRunning: Bool {
        lock.withLock { current != 0 }
    }

    /// Whether `generation` is still the run the user is waiting on. This is the
    /// question every exit of a transcription has to ask before it does anything
    /// the user can see.
    public func isRunning(_ generation: UInt64) -> Bool {
        lock.withLock { current == generation }
    }

    public func begin() -> UInt64 {
        lock.withLock {
            issued += 1
            current = issued
            return issued
        }
    }

    /// Ends only its own run. A transcription that finishes after the user has
    /// already started the next one must not tear that next one down.
    public func end(_ generation: UInt64) {
        lock.withLock {
            if current == generation { current = 0 }
        }
    }

    /// Takes the running dictation out of play and reports whether there was
    /// one.
    ///
    /// Called from the event tap *before* it returns its swallow decision, which
    /// is what closes an otherwise-real race: without it the tap would swallow
    /// the Escape, hop to the main actor to cancel, and a transcription
    /// completing in that same instant — also on the main actor — could win the
    /// hop and paste text the user had already cancelled.
    ///
    /// Idempotent, because the HUD's cancel button calls it too and neither
    /// caller cares which of them got there first.
    @discardableResult
    public func claimCancel() -> UInt64? {
        lock.withLock {
            guard current != 0 else { return nil }
            defer { current = 0 }
            return current
        }
    }
}
