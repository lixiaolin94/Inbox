import CloudKit
import Foundation

/// CKRecord field names and encode/decode for Inbox Record / Project.
/// recordName is the local UUID. Zone is always InboxZone.
enum CKRecordMapping {
    static let recordType = "Record"
    static let projectType = "Project"
    static let zoneName = "InboxZone"

    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let zone = CKRecordZone(zoneID: zoneID)

    static func recordID(forLocalID id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    static func makeRecord(from local: Record, metadata: Data?) -> CKRecord {
        let ckRecord = baseRecord(type: recordType, id: local.id, metadata: metadata)
        ckRecord["content"] = local.content as CKRecordValue
        ckRecord["priority"] = NSNumber(value: local.priority)
        ckRecord["status"] = NSNumber(value: local.status)
        ckRecord["projectID"] = local.projectID as CKRecordValue?
        ckRecord["createdAt"] = NSNumber(value: local.createdAt)
        ckRecord["updatedAt"] = NSNumber(value: local.updatedAt)
        ckRecord["resolvedAt"] = local.resolvedAt.map(NSNumber.init(value:))
        ckRecord["deletedAt"] = local.deletedAt.map(NSNumber.init(value:))
        return ckRecord
    }

    static func makeProject(from local: Project, metadata: Data?) -> CKRecord {
        let ckRecord = baseRecord(type: projectType, id: local.id, metadata: metadata)
        ckRecord["name"] = local.name as CKRecordValue
        ckRecord["manualOrder"] = NSNumber(value: local.manualOrder)
        ckRecord["createdAt"] = NSNumber(value: local.createdAt)
        ckRecord["updatedAt"] = NSNumber(value: local.updatedAt)
        return ckRecord
    }

    static func recordFields(from ckRecord: CKRecord) -> ConflictMerger.RecordFields {
        ConflictMerger.RecordFields(
            content: string(ckRecord, "content") ?? "",
            priority: Int(int64(ckRecord, "priority") ?? 2),
            status: Int(int64(ckRecord, "status") ?? 0),
            projectID: string(ckRecord, "projectID"),
            createdAt: int64(ckRecord, "createdAt") ?? 0,
            updatedAt: int64(ckRecord, "updatedAt") ?? 0,
            resolvedAt: int64(ckRecord, "resolvedAt"),
            deletedAt: int64(ckRecord, "deletedAt")
        )
    }

    static func projectFields(from ckRecord: CKRecord) -> ConflictMerger.ProjectFields {
        ConflictMerger.ProjectFields(
            name: string(ckRecord, "name") ?? "",
            manualOrder: int64(ckRecord, "manualOrder") ?? 0,
            createdAt: int64(ckRecord, "createdAt") ?? 0,
            updatedAt: int64(ckRecord, "updatedAt") ?? 0
        )
    }

    static func packMetadata(from ckRecord: CKRecord, ancestorJSON: String) -> Data {
        CKLocalMetadata.pack(systemFields: encodeSystemFields(ckRecord), ancestorJSON: ancestorJSON)
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private static func baseRecord(type: String, id: String, metadata: Data?) -> CKRecord {
        if let metadata,
           let unpacked = CKLocalMetadata.unpack(metadata),
           let existing = decodeSystemFields(unpacked.systemFields) {
            return existing
        }
        return CKRecord(recordType: type, recordID: recordID(forLocalID: id))
    }

    private static func string(_ record: CKRecord, _ key: String) -> String? {
        record[key] as? String
    }

    private static func int64(_ record: CKRecord, _ key: String) -> Int64? {
        if let number = record[key] as? Int64 { return number }
        if let number = record[key] as? Int { return Int64(number) }
        if let number = record[key] as? NSNumber { return number.int64Value }
        return nil
    }
}
