import AppKit
import Foundation

/// Types text into whatever app the user is currently in.
///
/// There is no public API to insert text into an arbitrary app, so this does
/// what every dictation tool does: put the text on the pasteboard, synthesise
/// Cmd-V, then put the user's clipboard back. Requires Accessibility.
public enum TextInserter {
    public enum InsertError: LocalizedError {
        case accessibilityNotGranted
        case eventCreationFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                "FreeWhisper needs Accessibility permission to type into other apps."
            case .eventCreationFailed:
                "Could not synthesise a keystroke."
            }
        }
    }

    /// How long to wait before restoring the clipboard. The paste is delivered
    /// asynchronously to the target app, so restoring immediately would race it
    /// and paste the user's old clipboard contents instead.
    static let restoreDelay: TimeInterval = 0.4

    public static func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityNotGranted }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        do {
            try postPaste()
        } catch {
            restore(saved, to: pasteboard)
            throw error
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, to: pasteboard)
        }
    }

    // MARK: Keystroke

    private static func postPaste() throws {
        // A dedicated event source keeps our synthetic keys from being merged
        // with whatever physical modifiers the user happens to be holding —
        // dictation is usually triggered by a hotkey that is still down.
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false)
        else {
            throw InsertError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static let kVK_ANSI_V: CGKeyCode = 0x09

    // MARK: Pasteboard preservation

    /// Everything on the pasteboard, so a restore brings back rich content and
    /// not just a plain-text approximation of it.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restored = snapshot.items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
