import Foundation

/// Decides when a capture stream has stopped producing audio and should be
/// rebuilt.
///
/// Both capture paths can die mid-meeting and neither says so. The engine stops
/// itself on a configuration change; the process tap is stranded when the device
/// behind the aggregate goes away. Watching for the *causes* is what the old
/// output-device listener did, and it only ever caught one of them — a stream
/// that stopped for any other reason sat dead for the rest of the call.
///
/// So watch the effect instead. A stream that is alive is writing samples, and
/// captured seconds that stop advancing mean it is gone, whatever killed it.
struct StreamWatchdog {
    /// How long a stream may produce nothing before it counts as dead.
    ///
    /// Silence is not the same as nothing: a muted microphone still writes
    /// zeroes at the full sample rate, so a stream whose captured seconds stop
    /// advancing is not quiet, it has stopped. The tolerance only has to cover
    /// scheduling jitter and the device's own buffer size, both far under a
    /// second — five is generous, and the cost of being wrong is one seam.
    static let stallTolerance: TimeInterval = 5

    /// Restarts are rate-limited, doubling from here up to ``maximumBackoff``.
    /// A device that is genuinely gone — an interface unplugged for the rest of
    /// the meeting — would otherwise have us minting a new file every five
    /// seconds until it ends.
    static let minimumBackoff: TimeInterval = 5
    static let maximumBackoff: TimeInterval = 60

    /// Captured seconds a rebuilt stream must deliver before the backoff is
    /// forgiven. Comfortably longer than the stall tolerance, so a stream that
    /// flaps once per restart cannot keep resetting itself to a fast retry.
    static let recoverySeconds: TimeInterval = 20

    /// The most captured audio this stream has reported.
    private var captured: TimeInterval = 0
    /// When that last went up — the stream's last sign of life.
    private var lastAdvance: Date
    /// Restarts since the stream was last healthy, which sets the backoff.
    private var consecutiveRestarts = 0
    private var lastRestart: Date?
    private var capturedAtLastRestart: TimeInterval = 0

    init(startedAt: Date) {
        self.lastAdvance = startedAt
    }

    /// Whether the stream should be rebuilt now.
    ///
    /// `forced` is the stream's own report that it knows it is broken — an
    /// audio configuration change, an output device swapped out. It skips the
    /// wait for the stall to show up in the numbers but still respects the
    /// backoff, because a Bluetooth device flapping produces a burst of these.
    mutating func shouldRestart(
        captured: TimeInterval,
        forced: Bool,
        now: Date = Date()
    ) -> Bool {
        if captured > self.captured {
            self.captured = captured
            lastAdvance = now
            if captured - capturedAtLastRestart >= Self.recoverySeconds {
                consecutiveRestarts = 0
            }
        }

        let stalled = now.timeIntervalSince(lastAdvance) > Self.stallTolerance
        guard forced || stalled else { return false }

        if let lastRestart, now.timeIntervalSince(lastRestart) < backoff {
            return false
        }

        consecutiveRestarts += 1
        lastRestart = now
        capturedAtLastRestart = captured
        // The rebuilt stream needs its own grace period before the silence it
        // has not filled yet reads as another stall.
        lastAdvance = now
        return true
    }

    /// How long to wait before the *next* restart, doubling each time.
    ///
    /// The first restart is not delayed at all — `lastRestart` is nil, so there
    /// is nothing to wait behind. A headset being plugged in is the case this
    /// whole mechanism exists for, and making the user lose five seconds of it
    /// to guard against a loop that has not happened yet is the wrong trade.
    var backoff: TimeInterval {
        guard consecutiveRestarts > 0 else { return 0 }
        let doublings = Double(consecutiveRestarts - 1)
        return min(Self.maximumBackoff, Self.minimumBackoff * pow(2, doublings))
    }
}
