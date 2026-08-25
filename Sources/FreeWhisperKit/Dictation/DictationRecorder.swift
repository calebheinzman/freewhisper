import AVFoundation
import Foundation

/// Records a short microphone clip for dictation.
///
/// Separate from `RecordingSession` on purpose: dictation is mic-only, never
/// touches the system tap, and writes to a temporary file that is deleted
/// straight after transcription. Nothing the user dictates is kept.
public final class DictationRecorder {
    private let recorder = MicRecorder()
    private var url: URL?

    public private(set) var isRecording = false

    public init() {}

    public var level: Float {
        ResamplingRecorder.meterScale(recorder.level)
    }

    public func start() throws {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freewhisper-dictation-\(UUID().uuidString).wav")
        try recorder.start(writingTo: url)
        self.url = url
        isRecording = true
    }

    /// Stops and returns the clip, or nil if nothing usable was captured.
    /// The caller owns the file and should delete it when done.
    public func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        recorder.stop()
        guard let url else { return nil }
        self.url = nil

        // A hotkey tapped by accident produces a fraction of a second of
        // silence; transcribing it just makes Whisper hallucinate.
        guard recorder.peak >= ResamplingRecorder.silenceThreshold else {
            try? FileManager.default.removeItem(at: url)
            Log.dictation.notice("discarded silent dictation clip")
            return nil
        }
        return url
    }

    public func cancel() {
        guard isRecording else { return }
        isRecording = false
        recorder.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}
