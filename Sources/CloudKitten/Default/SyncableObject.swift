//
//  SyncableObject.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 06.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

public protocol SyncableObject: NSManagedObject, RecordIDConvertible {
    static func existing(with recordID: RecordID, context: NSManagedObjectContext) throws -> Self?
    static func create(with recordID: RecordID, context: NSManagedObjectContext) -> Self
    
    static func merge(record: Record, with localChange: LocalChange?, context: NSManagedObjectContext) -> (RecordPullResult, SyncableObject?)
    
    static func update(with record: Record, context: NSManagedObjectContext) -> (RecordPullResult, Self?)
    func update(with record: Record) -> RecordPullResult
    
    func handleMissingRelationshipTargets(for record: Record) -> RecordPullResult
    func handleValidationError(for recordID: RecordID) -> RecordPullResult
    
    static func updateSystemFields(with record: Record, context: NSManagedObjectContext) throws
    func setSystemFieldsRecord(_ record: CKRecord)
    
    // Pull Manager
    static func delete(with recordID: RecordID, in context: NSManagedObjectContext) -> (RecordPullResult, Self?)
    static func delete(with zoneID: CKRecordZone.ID, in context: NSManagedObjectContext) throws
    
    // Push Manager
    func createRecord() -> CKRecord?
}

public protocol RecordIDConvertible {
    var recordID: RecordID? { get }
}

public protocol PersistentHistoryCompatible {
    static func recordID(from tombstone: Tombstone) -> RecordID?
    
    #warning("TODO: rethink this API, since now both push & pull contexts are ignored")
    static func considerUpdated(updatedProperties: Set<NSPropertyDescription>) -> Bool
}

public enum LocalChange {
    case deleted(timestamp: Date?)
    case updated(timestamp: Date?, managedObjectID: NSManagedObjectID)
    
    var timestamp: Date? {
        switch self {
        case let .deleted(timestamp), let .updated(timestamp, _):
            return timestamp
        }
    }
}

public protocol EntityHandling {
    static func entityName(from recordType: CKRecord.RecordType) -> String
    static func entityName(from objectID: NSManagedObjectID) -> String?
    
    static func handlesEntity(name: String) -> Bool
}

public protocol RecordIDProperties {
    static var databaseScopePropertyName: String { get } // CD NSNumber (treated as Int)
    
    static var recordNamePropertyName: String { get } // CD String
    static var zoneNamePropertyName: String { get } // CD String
    static var ownerNamePropertyName: String { get } // CD String
}

public protocol SystemFieldsProperty {
    static var systemFieldsPropertyName: String { get }
}

public protocol ModificationTimeFieldKey {
    static var modificationTimeFieldKey: String { get }
}

// MARK: - Implementation

extension NSManagedObject: EntityHandling {
    public static func entityName(from recordType: CKRecord.RecordType) -> String {
        recordType
    }

    public static func entityName(from objectID: NSManagedObjectID) -> String? {
        objectID.entity.name
    }
    
    public static func handlesEntity(name: String) -> Bool {
        name == entity().name!
    }
}

public extension SyncableObject {
    static func update(with record: Record, context: NSManagedObjectContext) -> (RecordPullResult, Self?) {
        // TODO: changeStore compare as in CoreDataObjectCloudKitBridge
        
        do {
            let syncableObject = try Self.existing(with: record.recordID, context: context) ?? Self.create(with: record.recordID, context: context)
            return (syncableObject.update(with: record), syncableObject)
        } catch {
            return (.error(error), nil)
        }
    }
    
    static func delete(with recordID: RecordID, in context: NSManagedObjectContext) -> (RecordPullResult, Self?) {
        do {
            let object = try Self.existing(with: recordID, context: context)
            if let object = object { context.delete(object) }
            return (.merged, object)
        } catch {
            return (.error(error), nil)
        }
    }
    
    static func delete(with zoneID: CKRecordZone.ID, in context: NSManagedObjectContext) throws {
        let request: NSFetchRequest<Self> = NSFetchRequest(entityName: entity().name!)
        request.returnsObjectsAsFaults = false // better performance since we will fire all faults
        for object in try context.fetch(request) where object.recordID?.recordID.zoneID == zoneID {
            context.delete(object)
        }
    }
    
    func handleMissingRelationshipTargets(`for` record: Record) -> RecordPullResult {
        .unmerged
    }
    
    func handleValidationError(`for` recordID: RecordID) -> RecordPullResult {
        .unmerged
    }
    
    static func considerUpdated(updatedProperties: Set<NSPropertyDescription>) -> Bool {
        true
    }
}

public extension SyncableObject where Self: RecordIDProperties {
    static func existing(with recordID: RecordID, context: NSManagedObjectContext) throws -> Self? {
        let request: NSFetchRequest<Self> = NSFetchRequest(entityName: entity().name!)
        request.predicate = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@ AND %K == %@",
            Self.databaseScopePropertyName, NSNumber(value: recordID.databaseScope.rawValue),
            Self.recordNamePropertyName, recordID.recordID.recordName,
            Self.zoneNamePropertyName, recordID.recordID.zoneID.zoneName,
            Self.ownerNamePropertyName, recordID.recordID.zoneID.ownerName
        )
        let results = try context.fetch(request)
        assert(results.count <= 1, "Warning: More than one managed object exists for the same recordID.")
        return results.first
    }
    
    static func create(with recordID: RecordID, context: NSManagedObjectContext) -> Self {
        let object = Self(context: context)
        object.setValue(recordID.databaseScope.rawValue, forKey: Self.databaseScopePropertyName)
        object.setValue(recordID.recordID.recordName, forKey: Self.recordNamePropertyName)
        object.setValue(recordID.recordID.zoneID.zoneName, forKey: Self.zoneNamePropertyName)
        object.setValue(recordID.recordID.zoneID.ownerName, forKey: Self.ownerNamePropertyName)
        return object
    }
    
    var recordID: RecordID? {
        get {
            guard let rawDatabaseScope = value(forKey: Self.databaseScopePropertyName) as? NSNumber else { return nil }
            guard let databaseScope = CKDatabase.Scope(rawValue: rawDatabaseScope.intValue) else { return nil }
            guard let recordName = value(forKey: Self.recordNamePropertyName) as? String else { return nil }
            guard let zoneName = value(forKey: Self.zoneNamePropertyName) as? String else { return nil }
            guard let ownerName = value(forKey: Self.ownerNamePropertyName) as? String else { return nil }
            
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            
            return RecordID(recordID: recordID, databaseScope: databaseScope)
        }
        // convenience setter
        set {
            setValue(newValue?.databaseScope.rawValue, forKey: Self.databaseScopePropertyName)
            setValue(newValue?.recordID.recordName, forKey: Self.recordNamePropertyName)
            setValue(newValue?.recordID.zoneID.zoneName, forKey: Self.zoneNamePropertyName)
            setValue(newValue?.recordID.zoneID.ownerName, forKey: Self.ownerNamePropertyName)
        }
    }
    
    static func recordID(from tombstone: Tombstone) -> RecordID? {
        guard let rawDatabaseScope = tombstone[Self.databaseScopePropertyName] as? Int else { return nil }
        guard let databaseScope = CKDatabase.Scope(rawValue: rawDatabaseScope) else { return nil }
        guard let recordName = tombstone[Self.recordNamePropertyName] as? String else { return nil }
        guard let zoneName = tombstone[Self.zoneNamePropertyName] as? String else { return nil }
        guard let ownerName = tombstone[Self.ownerNamePropertyName] as? String else { return nil }
        
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        return RecordID(recordID: recordID, databaseScope: databaseScope)
    }
}

public extension SyncableObject where Self: SystemFieldsProperty {
    static func updateSystemFields(with record: Record, context: NSManagedObjectContext) throws {
        try Self.existing(with: record.recordID, context: context)?.setSystemFieldsRecord(record.record)
    }
    
    func setSystemFieldsRecord(_ record: CKRecord) {
        setValue(record.encdodedSystemFields, forKey: Self.systemFieldsPropertyName)
    }
    
    static func considerUpdated(updatedProperties: Set<NSPropertyDescription>) -> Bool {
        updatedProperties.contains { $0.name != Self.systemFieldsPropertyName }
    }
}

// MARK: - Convenience

public extension SyncableObject {
    func emptyRecord() -> CKRecord? {
        guard let recordType = Self.entityName(from: objectID) else { return nil }
        guard let recordID = recordID else { return nil }
        return CKRecord(recordType: recordType, recordID: recordID.recordID)
    }
}

public extension SyncableObject where Self: SystemFieldsProperty {
    var systemFieldsRecord: CKRecord? {
        guard let systemFields = value(forKey: Self.systemFieldsPropertyName) as? Data, let record = CKRecord(archivedData: systemFields) else { return nil }
        guard record.recordID == self.recordID?.recordID else { return nil }
        return record
    }
}

// MARK: - Merge Policy

import os.log
public extension SyncableObject where Self: ModificationTimeFieldKey {
    static func merge(record: Record, with localChange: LocalChange?, context: NSManagedObjectContext) -> (RecordPullResult, SyncableObject?) {
        if let localChange = localChange, let clientModificationTime = localChange.timestamp {
            let serverModificationTime = record.record[Self.modificationTimeFieldKey] as? Date
            if keepClientVersion(clientModificationTime: clientModificationTime, serverModificationTime: serverModificationTime) {
                os_log("Keeping client version. (client modification time=%@, server modification time=%@)", log: .conflictResolution, type: .info, clientModificationTime as NSDate? ?? "nil", serverModificationTime as NSDate? ?? "nil")
                guard case let .updated(_, objectID) = localChange else {
                    os_log("Keeping changes (deletion) of local object", log: .conflictResolution, type: .info)
                    return (.merged, nil)
                }
                if let syncableObject = try? context.existingObject(with: objectID) as? SyncableObject, syncableObject.recordID == record.recordID {
                    os_log("Keeping changes of local object=%@", log: .conflictResolution, type: .info, objectID)
                    return (.merged, syncableObject)
                } else {
                    os_log("No SyncableObject for object=%@, or wrong recordID, falling back to using server version", log: .conflictResolution, type: .error, objectID)
                }
            }
        }
        return update(with: record, context: context)
    }
    
    private static func keepClientVersion(clientModificationTime: Date?, serverModificationTime: Date?) -> Bool {
        /*
         last writer wins merge policy (some trumps nil, server trumps client)
         
         +--------------------+--------------------+----------------------+
         |                    | server date == nil | server date == b     |
         +--------------------+--------------------+----------------------+
         | client date == nil | server wins        | server wins          |
         +--------------------+--------------------+----------------------+
         | client date == a   | client wins        | client wins if a > b |
         +--------------------+--------------------+----------------------+
         */
        guard let clientModificationTime = clientModificationTime else { return false }
        guard let serverModificationTime = serverModificationTime else { return true }
        return clientModificationTime > serverModificationTime
    }
}

// MARK: - Legacy
#warning("TODO replace by something better")

public enum RecordPullResult {
    /// Everything went as expected
    case merged
    
    /// `update(_ managedObject: NSManagedObject, with record: CKRecord)` will be called again later
    case missingRelationshipTargets
    
    /// The managed object will be refreshed and the recordID will be saved in the `FailedRecordStore`
    case unmerged
    /// The managed object will be refreshed and the pull will be aborted, the server token will not be updated.
    case error(Error)
}

//enum UpdateResult {
//    case pullResultAction(PullResultAction)
//    case missingRelationshipTargets
//}
//
//enum PullResultAction {
//    case markSuccessful
//    case markFailed
//    case error(Error)
//}
//
