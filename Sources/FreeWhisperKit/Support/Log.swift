import Foundation
import os

/// Shared subsystem so `log stream --predicate 'subsystem == "dev.freewhisper.FreeWhisper"'`
/// picks up everything, including logs from `fwctl`.
public enum Log {
    public static let subsystem = "dev.freewhisper.FreeWhisper"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let detection = Logger(subsystem: subsystem, category: "detection")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let dictation = Logger(subsystem: subsystem, category: "dictation")
    public static let llm = Logger(subsystem: subsystem, category: "llm")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
