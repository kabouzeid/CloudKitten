//
//  PullManager.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 26.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import CoreData
import os.log

public class PullManager {
    public typealias PullObject = (SyncableObject)
    private let registeredTypes: [PullObject.Type]
    private let context: NSManagedObjectContext
    private let changeStore: ChangeStore
    private let databaseScope: CKDatabase.Scope
    
    init(pullObjectTypes: [PullObject.Type], context: NSManagedObjectContext, changeStore: ChangeStore, storage: StorageProvider, databaseScope: CKDatabase.Scope) {
        self.registeredTypes = pullObjectTypes
        self.context = context
        self.changeStore = changeStore
        self.databaseScope = databaseScope
        
        _failedRecords = .init(storage: storage, key: Self.failedRecordsStorageKey, default: [])
    }
    
    private var pullResults = [RecordDescription : RecordPullResult]()
    
    var errors: [Error] {
        Array(recordErrors.values) + Array(zoneErrors.values) + (databaseError.map { [$0] } ?? [])
    }
    
    private var recordErrors: [RecordDescription : Error] {
        pullResults.compactMapValues {
            if case .error(let error) = $0 {
                return error
            }
            return nil
        }
    }
    private var zoneErrors = [CKRecordZone.ID : Error]()
    private var databaseError: Error? = nil
    
    static let failedRecordsStorageKey = "failedRecords"
    
    @Stored private(set) var failedRecords: Set<RecordDescription>
    
    private var syncableObjectRecordMap = [NSManagedObjectID : RecordDescription]() // used to get record descriptions for invalid objects
    private var syncableObjectsWithMissingRelationshipTargets = [CKRecordZone.ID : [(SyncableObject, Record)]]()
}

extension PullManager {
    func updateManagedObject(record: CKRecord) {
        context.performAndWait {
            os_log("Init managed object for record with recordType=%@ recordID=%@", log: .sync, type: .debug, record.recordType, record.recordID)
            let record = Record(record: record, databaseScope: databaseScope)
            let (result, syncableObject) = registeredType(for: record.record.recordType)?.merge(record: record, with: changeStore.change(for: record.recordID)?.localChange, context: context) ?? (.unmerged, nil)
            switch result {
            case .merged:
                if let syncableObject = syncableObject {
                    syncableObjectRecordMap[syncableObject.objectID] = RecordDescription(from: record)
                    syncableObject.setSystemFieldsRecord(record.record)
                }
            case .missingRelationshipTargets:
                guard let syncableObject = syncableObject else { fatalError() }
                syncableObjectsWithMissingRelationshipTargets[record.record.recordID.zoneID, default: []].append((syncableObject, record))
            case .unmerged, .error:
                if let syncableObject = syncableObject {
                    context.refresh(syncableObject, mergeChanges: false)
                }
            }
            
            pullResults[RecordDescription(from: record)] = result
        }
    }
    
    func updateManagedObjectsWithMissingRelationshipTargets() {
        for zoneID in self.syncableObjectsWithMissingRelationshipTargets.keys {
            updateManagedObjectsWithMissingRelationshipTargets(in: zoneID)
        }
    }
    
    func updateManagedObjectsWithMissingRelationshipTargets(in zoneID: CKRecordZone.ID) {
        context.performAndWait {
            guard let syncableObjects = self.syncableObjectsWithMissingRelationshipTargets[zoneID] else { return }
            self.syncableObjectsWithMissingRelationshipTargets[zoneID] = nil
            for (syncableObject, record) in syncableObjects {
                let result = syncableObject.update(with: record)
                switch result {
                case .merged:
                    syncableObject.setSystemFieldsRecord(record.record)
                case .missingRelationshipTargets:
                    syncableObjectsWithMissingRelationshipTargets[record.record.recordID.zoneID, default: []].append((syncableObject, record))
                case .unmerged, .error:
                    context.refresh(syncableObject, mergeChanges: false)
                }
                
                pullResults[RecordDescription(from: record)] = result
            }
        }
    }
    
    func hasManagedObjectsWithMissingRelationshipTargets(in zoneID: CKRecordZone.ID) -> Bool {
        !(syncableObjectsWithMissingRelationshipTargets[zoneID]?.isEmpty ?? true)
    }
    
    func handleManagedObjectsWithMissingRelationshipTargets() {
        for zoneID in self.syncableObjectsWithMissingRelationshipTargets.keys {
            handleManagedObjectsWithMissingRelationshipTargets(in: zoneID)
        }
    }
    
    func handleManagedObjectsWithMissingRelationshipTargets(in zoneID: CKRecordZone.ID) {
        context.performAndWait {
            guard let objects = self.syncableObjectsWithMissingRelationshipTargets[zoneID] else { return }
            self.syncableObjectsWithMissingRelationshipTargets[zoneID] = nil
            for (syncableObject, record) in objects {
                os_log("Managed object is still missing relationship targets during record zone fetch completion objectID=%@", log: .sync, syncableObject.objectID)
                let result = syncableObject.handleMissingRelationshipTargets(for: record)
                switch result {
                case .merged:
                    syncableObject.setSystemFieldsRecord(record.record)
                case .missingRelationshipTargets:
                    fatalError()
                case .unmerged, .error:
                    context.refresh(syncableObject, mergeChanges: false)
                }
                
                pullResults[RecordDescription(from: record)] = result
            }
        }
    }
    
    func deleteManagedObject(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        context.performAndWait {
            os_log("Deleting managedObject for record with recordType=%@ recordID=%@", log: .sync, type: .debug, recordType, recordID)
            let (result, syncableObject) = registeredType(for: recordType)?.delete(with: RecordID(recordID: recordID, databaseScope: databaseScope), in: context) ?? (.merged, nil)
            switch result {
            case .merged:
                if let syncableObject = syncableObject {
                    syncableObjectRecordMap[syncableObject.objectID] = .init(recordID: .init(recordID: recordID, databaseScope: databaseScope), recordType: recordType)
                }
            case .missingRelationshipTargets:
                fatalError()
            case .unmerged, .error:
                if let syncableObject = syncableObject {
                    context.refresh(syncableObject, mergeChanges: false)
                }
            }
            
            pullResults[.init(recordID: .init(recordID: recordID, databaseScope: databaseScope), recordType: recordType)] = result
        }
    }
    
    func save() throws {
        try context.performAndWait {
            let invalidObjects = try self.context.saveNonAtomic()
            if !invalidObjects.isEmpty { os_log("Could not save %d objects", log: .sync, type: .error, invalidObjects.count) }
            self.updatePullResults(with: invalidObjects)
            try self.saveUnmergedRecordDescriptions()
        }
    }
    
    private func updatePullResults(with invalidObjects: Set<NSManagedObject>) {
        for invalidObject in invalidObjects {
            guard let syncableObject = invalidObject as? SyncableObject else {
                assertionFailure("Object is not a SyncableObject objectID=\(invalidObject.objectID)")
                continue
            }
            
            let fallbackRecordDescription = { () -> RecordDescription? in
                guard let record = syncableObject.emptyRecord() else { return nil }
                return RecordDescription(from: Record(record: record, databaseScope: self.databaseScope))
            }
            
            guard let recordDescription = self.syncableObjectRecordMap[syncableObject.objectID] ?? fallbackRecordDescription() else {
                assertionFailure("Could not find RecordDescription for object objectID=\(syncableObject.objectID)")
                continue
            }
            
            let result = syncableObject.handleValidationError()
            switch result {
            case .merged:
                break
            case .missingRelationshipTargets:
                fatalError()
            case .unmerged, .error:
                break
            }
            self.pullResults[recordDescription] = result
        }
    }
    
    private func saveUnmergedRecordDescriptions() throws {
        var mergedRecordDescriptions = Set<RecordDescription>()
        var unmergedRecordDescriptions = Set<RecordDescription>()
        for (recordDescription, pullResult) in pullResults {
            switch pullResult {
            case .merged:
                mergedRecordDescriptions.insert(recordDescription)
            case .unmerged:
                unmergedRecordDescriptions.insert(recordDescription)
            case .missingRelationshipTargets, .error(_):
                break
            }
        }
        
        failedRecords = failedRecords.subtracting(mergedRecordDescriptions).union(unmergedRecordDescriptions)
    }
}

extension PullManager {
    func delete(with zoneID: CKRecordZone.ID) {
        context.performAndWait {
            for registeredType in registeredTypes {
                do {
                    try registeredType.delete(with: zoneID, in: context)
                } catch {
                    zoneErrors[zoneID] = PullError.couldNotDeleteRecordZone(zoneID: zoneID)
                }
            }
        }
    }
    
    func delete(with databaseScope: CKDatabase.Scope) {
        context.performAndWait { [self] in
            for registeredType in registeredTypes {
                do {
                    try registeredType.delete(with: databaseScope, in: context)
                } catch {
                    databaseError = PullError.couldNotDeleteDatabase
                }
            }
        }
    }
}

extension PullManager {
    func hasErrors(for zoneID: CKRecordZone.ID) -> Bool {
        databaseError != nil || zoneErrors[zoneID] != nil || recordErrors.contains(where: { $0.key.recordID.recordID.zoneID == zoneID })
    }
}

extension PullManager {
    private func registeredType(for recordType: CKRecord.RecordType) -> PullObject.Type? {
        registeredTypes.first {
            $0.handlesEntity(name: $0.entityName(from: recordType))
        }
    }
}
