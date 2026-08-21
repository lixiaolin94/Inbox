import Foundation

/// Field-level three-way merge for Record and Project (PRD §15.3).
///
/// Inputs are plain values so tests do not need CloudKit. `ancestor` is the
/// last-acked snapshot (decoded from `ck_system_fields`); `nil` means the
/// row has never been uploaded, so every local≠server field is a conflict.
enum ConflictMerger {
    struct RecordFields: Equatable, Codable {
        var content: String
        var priority: Int
        var status: Int
        var projectID: String?
        var createdAt: Int64
        var updatedAt: Int64
        var resolvedAt: Int64?
        var deletedAt: Int64?
    }

    struct ProjectFields: Equatable, Codable {
        var name: String
        var manualOrder: Int64
        var createdAt: Int64
        var updatedAt: Int64
    }

    /// Content Keep Both duplicates the local content onto a new id; the
    /// original id keeps the server content so CloudKit's recordName stays
    /// stable. Scalar fields are still merged onto both copies.
    enum RecordOutcome: Equatable {
        case merged(RecordFields)
        case keepBoth(server: RecordFields, localDuplicate: RecordFields)
    }

    static func mergeRecord(
        local: RecordFields,
        server: RecordFields,
        ancestor: RecordFields?
    ) -> RecordOutcome {
        let contentConflict = isSameFieldConflict(
            local: local.content,
            server: server.content,
            ancestor: ancestor?.content
        )
        let priority = mergeScalar(
            local: local.priority,
            server: server.priority,
            ancestor: ancestor?.priority,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let status = mergeScalar(
            local: local.status,
            server: server.status,
            ancestor: ancestor?.status,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let projectID = mergeScalar(
            local: local.projectID,
            server: server.projectID,
            ancestor: ancestor?.projectID,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let resolvedAt = mergeScalar(
            local: local.resolvedAt,
            server: server.resolvedAt,
            ancestor: ancestor?.resolvedAt,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let deletedAt = mergeScalar(
            local: local.deletedAt,
            server: server.deletedAt,
            ancestor: ancestor?.deletedAt,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let updatedAt = max(local.updatedAt, server.updatedAt)

        if contentConflict {
            let serverVersion = RecordFields(
                content: server.content,
                priority: priority,
                status: status,
                projectID: projectID,
                createdAt: server.createdAt,
                updatedAt: updatedAt,
                resolvedAt: resolvedAt,
                deletedAt: deletedAt
            )
            let localDuplicate = RecordFields(
                content: local.content,
                priority: priority,
                status: status,
                projectID: projectID,
                createdAt: local.createdAt,
                updatedAt: updatedAt,
                resolvedAt: resolvedAt,
                deletedAt: deletedAt
            )
            return .keepBoth(server: serverVersion, localDuplicate: localDuplicate)
        }

        let content = pickNonConflict(
            local: local.content,
            server: server.content,
            ancestor: ancestor?.content
        )
        return .merged(
            RecordFields(
                content: content,
                priority: priority,
                status: status,
                projectID: projectID,
                createdAt: local.createdAt,
                updatedAt: updatedAt,
                resolvedAt: resolvedAt,
                deletedAt: deletedAt
            )
        )
    }

    /// Project name and manual_order are scalars: different-field edits
    /// merge; same-field conflict takes the newer `updated_at`. Keep Both
    /// is not used for Project — a duplicate Project would split Record
    /// membership and break Manual Order (PRD §7.4 / §15.1).
    static func mergeProject(
        local: ProjectFields,
        server: ProjectFields,
        ancestor: ProjectFields?
    ) -> ProjectFields {
        let name = mergeScalar(
            local: local.name,
            server: server.name,
            ancestor: ancestor?.name,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        let manualOrder = mergeScalar(
            local: local.manualOrder,
            server: server.manualOrder,
            ancestor: ancestor?.manualOrder,
            localTime: local.updatedAt,
            serverTime: server.updatedAt
        )
        return ProjectFields(
            name: name,
            manualOrder: manualOrder,
            createdAt: local.createdAt,
            updatedAt: max(local.updatedAt, server.updatedAt)
        )
    }

    /// Both sides changed the value away from ancestor (or there is no
    /// ancestor and they differ). Equal values are never a conflict.
    static func isSameFieldConflict<T: Equatable>(local: T, server: T, ancestor: T?) -> Bool {
        if local == server { return false }
        if let ancestor {
            return local != ancestor && server != ancestor
        }
        return true
    }

    /// Scalar same-field conflict: newer `updated_at` wins. A timestamp tie
    /// takes the server value so two devices converge without a coin flip.
    static func mergeScalar<T: Equatable>(
        local: T,
        server: T,
        ancestor: T?,
        localTime: Int64,
        serverTime: Int64
    ) -> T {
        if local == server { return local }
        if let ancestor {
            if local == ancestor { return server }
            if server == ancestor { return local }
        }
        if localTime > serverTime { return local }
        return server
    }

    private static func pickNonConflict<T: Equatable>(local: T, server: T, ancestor: T?) -> T {
        if local == server { return local }
        if let ancestor {
            if local == ancestor { return server }
            if server == ancestor { return local }
        }
        return server
    }
}

extension ConflictMerger.RecordFields {
    init(_ record: Record) {
        self.init(
            content: record.content,
            priority: record.priority,
            status: record.status,
            projectID: record.projectID,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            resolvedAt: record.resolvedAt,
            deletedAt: record.deletedAt
        )
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func fromJSON(_ string: String) -> ConflictMerger.RecordFields? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConflictMerger.RecordFields.self, from: data)
    }
}

extension ConflictMerger.ProjectFields {
    init(_ project: Project) {
        self.init(
            name: project.name,
            manualOrder: project.manualOrder,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func fromJSON(_ string: String) -> ConflictMerger.ProjectFields? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConflictMerger.ProjectFields.self, from: data)
    }
}
