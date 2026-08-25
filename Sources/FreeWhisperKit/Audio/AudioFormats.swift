import AVFoundation
import Foundation

public enum AudioFormats {
    /// Every ASR engine we support (Whisper, Parakeet) and every diarizer wants
    /// 16 kHz mono, so we resample once at capture time rather than keeping
    /// 48 kHz stereo around and converting repeatedly later. A one-hour meeting
    /// is ~115 MB at 16-bit/16 kHz per channel instead of ~1.4 GB.
    public static let sampleRate: Double = 16_000
    public static let channelCount: AVAudioChannelCount = 1

    /// In-memory format used between the converter and AVAudioFile.
    public static var processing: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    /// On-disk format: 16-bit PCM WAV, which every tool can open.
    public static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
