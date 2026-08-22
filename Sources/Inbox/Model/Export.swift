import Foundation

/// The standard JSON export promised in PRD §16.1: every Project and every
/// Record row that still exists — open, resolved and trashed alike, nothing
/// filtered — plus enough metadata to tell the file apart later.
///
/// JSON keys are the SQLite column names from docs/SCHEMA.md (snake_case),
/// so a script written against the database reads the export unchanged.
/// Sync bookkeeping (`ck_system_fields`, `pending_change`, `tombstone`) is
/// device-local state, not user data, and is deliberately left out.
enum InboxExport {
    static let formatVersion = 1

    struct Document: Codable, Equatable {
        var formatVersion: Int
        /// Unix milliseconds, the same clock as every timestamp column.
        var exportedAt: Int64
        /// The same instant, human-readable (UTC).
        var exportedAtISO8601: String
        /// "Inbox <CFBundleShortVersionString>", or just "Inbox" for the
        /// naked SPM binary that has no bundle.
        var app: String
        /// `PRAGMA user_version` of the database the rows came from.
        var schemaVersion: Int
        var projects: [Project]
        var records: [Record]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case exportedAt = "exported_at"
            case exportedAtISO8601 = "exported_at_iso8601"
            case app
            case schemaVersion = "schema_version"
            case projects
            case records
        }

        init(projects: [Project], records: [Record], schemaVersion: Int, exportedAt: Date = Date()) {
            formatVersion = InboxExport.formatVersion
            self.exportedAt = Int64(exportedAt.timeIntervalSince1970 * 1000)
            exportedAtISO8601 = ISO8601DateFormatter().string(from: exportedAt)
            app = InboxExport.appDescription
            self.schemaVersion = schemaVersion
            self.projects = projects
            self.records = records
        }
    }

    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> Document {
        try JSONDecoder().decode(Document.self, from: data)
    }

    private static var appDescription: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return "Inbox"
        }
        return "Inbox \(version)"
    }
}

// Codable lives here rather than in the model files: the models stay free
// of format concerns, and synthesis is unavailable from another file
// anyway, so both directions are written out.
extension Record: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case content
        case priority
        case status
        case projectID = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
        case deletedAt = "deleted_at"
        case conflictOf = "conflict_of"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            content: try container.decode(String.self, forKey: .content),
            priority: try container.decode(Int.self, forKey: .priority),
            status: try container.decode(Int.self, forKey: .status),
            projectID: try container.decodeIfPresent(String.self, forKey: .projectID),
            createdAt: try container.decode(Int64.self, forKey: .createdAt),
            updatedAt: try container.decode(Int64.self, forKey: .updatedAt),
            resolvedAt: try container.decodeIfPresent(Int64.self, forKey: .resolvedAt),
            deletedAt: try container.decodeIfPresent(Int64.self, forKey: .deletedAt),
            conflictOf: try container.decodeIfPresent(String.self, forKey: .conflictOf)
        )
    }

    /// Nil optionals come out as explicit `null` rather than a missing key,
    /// so every Record carries the same nine keys as the table has columns.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(priority, forKey: .priority)
        try container.encode(status, forKey: .status)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(resolvedAt, forKey: .resolvedAt)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(conflictOf, forKey: .conflictOf)
    }
}

extension Project: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case manualOrder = "manual_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            manualOrder: try container.decode(Int64.self, forKey: .manualOrder),
            createdAt: try container.decode(Int64.self, forKey: .createdAt),
            updatedAt: try container.decode(Int64.self, forKey: .updatedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(manualOrder, forKey: .manualOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
