import AppKit
import Capture
import Carbon.HIToolbox

/// The Docs canvas can expose a selected range in its input proxy without exposing the words
/// it represents. Chromium includes the top-level source URL when it copies the actual selection.
public enum GoogleDocsSelection {
    public static func read(from field: FocusedField, page: URL) async -> String? {
        guard let selection = field.selection, selection.length > 0,
              let key = await KeySynth.resolve("c"), !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            SystemPasteboard.queue.async {
                let board = NSPasteboard.general
                let result = copy(from: page, board: SystemPasteboardAccess(), sourceURL: {
                    board.string(forType: .init("org.chromium.source-url")).flatMap(URL.init(string:))
                }, copiedText: {
                    guard ClipboardWatcher.ignoredTypes.isDisjoint(with: board.types?.map(\.rawValue) ?? []) else { return nil }
                    return board.string(forType: .string)
                }, stillSelected: {
                    !IsSecureEventInputEnabled() && AppActivation().frontmostPID() == field.handle.pid
                        && field.handle.isFocused() && field.handle.isFocusedInApp() && field.handle.selectedRange() == selection
                }, sendCopy: { KeySynth.postCommand(key, to: field.handle.pid) })
                continuation.resume(returning: result)
            }
        }
    }

    static func copy(from page: URL, board: any PasteboardAccess, sourceURL: () -> URL?, copiedText: () -> String?,
                     stillSelected: () -> Bool, sendCopy: () -> Bool, timeout: Duration = .seconds(1)) -> String? {
        guard stillSelected() else { return nil }
        let baseline = board.changeCount
        let saved = board.snapshot()
        guard board.changeCount == baseline, stillSelected(), sendCopy() else { return nil }
        let deadline = ContinuousClock.now + timeout
        repeat {
            let count = board.changeCount
            if count != baseline, let source = sourceURL() {
                guard source == page else { return nil }
                let text = copiedText()
                guard board.changeCount == count else { return nil }
                _ = board.restore(saved)
                return stillSelected() ? text : nil
            }
            if ContinuousClock.now >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.015)
        } while true
    }
}
