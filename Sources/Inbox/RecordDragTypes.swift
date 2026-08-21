import AppKit

/// Local-only pasteboard type for Record-row drags (All View → group or Scope chip).
enum RecordDragTypes {
    static let recordID = NSPasteboard.PasteboardType("com.xiaolin.inbox.record-id")
}
