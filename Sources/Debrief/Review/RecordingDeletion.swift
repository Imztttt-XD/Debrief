import AppKit

/// "删除录音" and "删除复盘记录", with the same confirmation from the recording page and the
/// review page. Not while that recording is being reviewed: the pipeline would write the
/// review back as it finishes.
@MainActor
enum RecordingDeletion {
    /// Moves the audio to the Trash and removes the recording and its review. Returns whether
    /// it was deleted.
    @discardableResult
    static func deleteRecording(_ record: RecordingRecord, store: AppStore) -> Bool {
        guard confirm(L10n.tr("recording.delete.confirm", [name(record, store: store)]),
                      detail: L10n.tr("recording.delete.detail")) else { return false }
        do {
            try store.deleteRecording(record.id)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Removes the transcript and analysis, keeping the recording.
    @discardableResult
    static func deleteReview(_ record: RecordingRecord, store: AppStore) -> Bool {
        guard confirm(L10n.tr("review.delete.confirm", [name(record, store: store)]),
                      detail: L10n.tr("review.delete.detail")) else { return false }
        store.deleteReview(record.id)
        return true
    }

    /// "字节跳动 · 后端开发 · 一面（11月18日 14:00）"
    private static func name(_ record: RecordingRecord, store: AppStore) -> String {
        L10n.tr("recording.name", [ReviewText.title(record, store: store),
                                   record.startedAt.formatted(date: .abbreviated, time: .shortened)])
    }

    private static func confirm(_ message: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
