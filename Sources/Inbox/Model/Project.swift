import Foundation

/// A lightweight Record grouping and Scope (PRD §3.3) — not a page, workspace
/// or hierarchy. `manualOrder` is the single order shared by the Scope Bar,
/// the All View Project Group order (S3b), and the `⌘2…⌘0` mapping (PRD §7.4).
struct Project: Equatable {
    let id: String
    var name: String
    var manualOrder: Int64
    let createdAt: Int64
    var updatedAt: Int64
}
