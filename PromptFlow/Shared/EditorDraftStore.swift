import Foundation

/// The script editor's unsaved text, kept outside the editor until the user
/// saves or cancels. Folding or unfolding an iPhone Duo rebuilds the scripts
/// list and with it an open editor sheet; the next time that same editor
/// opens — the same script, or a new one — the text is back. In memory only.
@MainActor
enum EditorDraftStore {
    struct Draft: Equatable {
        /// `EditorMode.id` of the editor that wrote it.
        let editorID: String
        var title: String
        var content: String
    }

    private(set) static var draft: Draft?

    static func draft(for editorID: String) -> Draft? {
        draft?.editorID == editorID ? draft : nil
    }

    static func save(_ new: Draft) {
        draft = new
    }

    /// After Save, Cancel or Discard: the text is settled.
    static func clear() {
        draft = nil
    }
}
