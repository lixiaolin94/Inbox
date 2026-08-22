import AppKit
import UniformTypeIdentifiers

/// The app's modal prompts, kept together so both surfaces share wording
/// and layout. Each runs modally on the main thread and returns the answer;
/// callers decide where focus goes afterwards.
enum Dialogs {
    /// Save panel for File ▸ Export (PRD §16.1). Returns the chosen URL, or
    /// nil when cancelled. The panel itself asks before overwriting.
    static func saveExport(suggestedName: String, allowedExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(filenameExtension: allowedExtension) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Generic failure alert for a store write that did not commit. Callers
    /// that hold user input (Create, Inline Edit) restore it themselves —
    /// No Silent Data Loss.
    static func persistenceFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    /// Single-line name prompt (Create / Rename Project, PRD §7.5). Returns
    /// the trimmed name, or nil when cancelled or left empty.
    static func promptName(title: String, confirm: String, initial: String = "", placeholder: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func confirmDeleteProject(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Project “\(name)”?"
        alert.informativeText = "Records will not be deleted. They will move back to Inbox."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// High-cost, explicit confirmation for Permanent Delete (PRD §12.3).
    static func confirmPermanentDelete(_ targets: [Record]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if targets.count == 1 {
            alert.messageText = "Delete Permanently?"
            alert.informativeText = "“\(targets[0].content)” will be deleted forever. This cannot be undone."
        } else {
            alert.messageText = "Delete \(targets.count) Records Permanently?"
            alert.informativeText = "These records will be deleted forever. This cannot be undone."
        }
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
