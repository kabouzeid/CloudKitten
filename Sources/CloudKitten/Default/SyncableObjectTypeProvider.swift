//
//  SyncableObjectTypeProvider.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 06.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

protocol SyncableObjectTypeProvider {
    var syncableObjectTypes: [SyncableObject.Type] { get }
    
    func syncableObjectType(for recordType: CKRecord.RecordType) -> SyncableObject.Type?
    
    func syncableObjectType(for objectID: NSManagedObjectID) -> SyncableObject.Type?
}

// MARK: - Default

struct DefaultSyncableObjectBridge: SyncableObjectTypeProvider {
    var syncableObjectTypes: [SyncableObject.Type]
}

// MARK: - Implementation

extension SyncableObjectTypeProvider {
    func syncableObjectType(for recordType: CKRecord.RecordType) -> SyncableObject.Type? {
        syncableObjectTypes.first {
            $0.handlesEntity(name: $0.entityName(from: recordType))
        }
    }
    
    func syncableObjectType(for objectID: NSManagedObjectID) -> SyncableObject.Type? {
        syncableObjectTypes.first {
            guard let entityName = $0.entityName(from: objectID) else { return false }
            return $0.handlesEntity(name: entityName)
        }
    }
}

// MARK: - Convenience

extension SyncableObjectTypeProvider {
    func merge(record: Record, with localChange: LocalChange?, context: NSManagedObjectContext) -> (RecordPullResult, SyncableObject?) {
        syncableObjectType(for: record.record.recordType)?.merge(record: record, with: localChange, context: context) ?? (.unmerged, nil)
    }
    
    func update(with record: Record, context: NSManagedObjectContext) -> (RecordPullResult, SyncableObject?) {
        syncableObjectType(for: record.record.recordType)?.update(with: record, context: context) ?? (.unmerged, nil)
    }
    
    func updateSystemFields(with record: Record, context: NSManagedObjectContext) throws {
        try syncableObjectType(for: record.record.recordType)?.updateSystemFields(with: record, context: context)
    }
    
    func delete(with recordID: RecordID, recordType: CKRecord.RecordType, context: NSManagedObjectContext) -> (RecordPullResult, SyncableObject?) {
        syncableObjectType(for: recordType)?.delete(with: recordID, in: context) ?? (.merged, nil)
    }
    
    func delete(with zoneID: CKRecordZone.ID, context: NSManagedObjectContext) throws {
        var errors = [Error]()
        for syncableObjectType in syncableObjectTypes {
            do {
                try syncableObjectType.delete(with: zoneID, in: context)
            } catch {
                errors.append(error)
            }
        }
        if !errors.isEmpty {
            throw NSError(domain: String(describing: Self.self), code: 1, userInfo: ["detailedErrors" : errors])
        }
    }
}

//extension Collection where Element == (SyncableObject).Type {
//    func element(for recordType: CKRecord.RecordType) -> SyncableObject.Type? {
//        self.first {
//            $0.handlesEntity(name: $0.entityName(from: recordType))
//        }
//    }
//    
//    func element(for objectID: NSManagedObjectID) -> SyncableObject.Type? {
//        self.first {
//            guard let entityName = $0.entityName(from: objectID) else { return false }
//            return $0.handlesEntity(name: entityName)
//        }
//    }
//}
//
//let arr: [(SyncableObject).Type] = [Workout.self]
//let x = arr.element(for: "")
