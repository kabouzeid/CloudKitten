//
//  PushManager.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 06.05.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import CoreData
import os.log

public class PushManager {
    public typealias PushObject = (SyncableObject)
    private let registeredTypes: [PushObject.Type]
    private let context: NSManagedObjectContext
    private let changeStore: ChangeStore
    private let databaseScope: CKDatabase.Scope
    
    init(pushObjectTypes: [PushObject.Type], context: NSManagedObjectContext, changeStore: ChangeStore, databaseScope: CKDatabase.Scope) {
        self.registeredTypes = pushObjectTypes
        self.context = context
        self.changeStore = changeStore
        self.databaseScope = databaseScope
    }
    
    private(set) var recordsToSave = [CKRecord]()
    private(set) var recordIDsToDelete = [CKRecord.ID]()
    
    private var recordIDObjectIDMap = [CKRecord.ID : NSManagedObjectID]()
}

extension PushManager {
    func prepare() throws {
        try changeStore.updateChanges(context: context)
        
        context.performAndWait {
            for update in changeStore.updatedManagedObjectIDs() {
                guard let managedObject = try? context.existingObject(with: update.managedObjectID) else {
                    os_log("Managed object %@ in ChangeStore does not exist", log: .sync, type: .error, update.managedObjectID)
                    continue
                }
                
                guard let pushObject = managedObject as? PushObject else {
                    os_log("Managed object %@ is not a SyncableObject", log: .sync, type: .error, update.managedObjectID)
                    continue
                }
                
                guard pushObject.recordID?.databaseScope == self.databaseScope else { continue }
                
                os_log("Creating record for managed object %@", log: .sync, managedObject.objectID)
                guard let record = pushObject.createRecord() else { continue }
                
                if let modificationTimeFieldKeyProviding = pushObject as? ModificationTimeFieldKey {
                    os_log("Setting record timestamp=%@", log: .sync, type: .debug, (update.timestamp as NSDate?) ?? "nil")
                    let modificationTimeFieldKey = type(of: modificationTimeFieldKeyProviding).modificationTimeFieldKey
                    record[modificationTimeFieldKey] = update.timestamp
                }
                
                recordsToSave.append(record)
                recordIDObjectIDMap[record.recordID] = managedObject.objectID
            }
        }

        recordIDsToDelete = changeStore.deletedRecordIDs()
            .filter { $0.recordID.databaseScope == self.databaseScope }
            .map { $0.recordID.recordID }
    }
    
    /// Called when CloudKit can't save all records at once (`CKError.Code.limitExceeded`). If some records always need to be saved together, this method should be overwritten by the developer.
    func split(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID]) -> (([CKRecord], [CKRecord]), ([CKRecord.ID], [CKRecord.ID])) {
        (recordsToSave.halfed(), recordIDsToDelete.halfed())
    }
    
    func success(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) {
        let savedRecords = savedRecords.map { Record(record: $0, databaseScope: databaseScope) }
        let deletedRecordIDs = deletedRecordIDs.map { RecordID(recordID: $0, databaseScope: databaseScope) }
        
        context.performAndWait {
            os_log("Updating system fields for %d saved record", log: .sync, savedRecords.count)
            for record in savedRecords {
                do {
                    try registeredType(for: record.record.recordType)?.updateSystemFields(with: record, context: context)
                } catch {
                    os_log("Could not update system fields of object for recordID=%@: %@", log: .sync, type: .error, record.record.recordID, error.localizedDescription)
                    // continue though...
                }
            }
            do {
                try context.save()
            } catch {
                os_log("Could not save context: %@", log: .sync, type: .error, error.localizedDescription)
                // continue though...
            }
            
            os_log("Removing %d saved records and %d deleted record IDs from change store", log: .sync, savedRecords.count, deletedRecordIDs.count)
            changeStore.remove(recordIDs: savedRecords.map { $0.recordID })
            changeStore.remove(recordIDs: deletedRecordIDs)
        }
    }
}

extension PushManager {
    private func registeredType(for recordType: CKRecord.RecordType) -> PushObject.Type? {
        registeredTypes.first {
            $0.handlesEntity(name: $0.entityName(from: recordType))
        }
    }
}


private extension Array {
    func halfed() -> ([Element], [Element]) {
        (Array(self[0 ..< (count / 2)]), Array(self[(count / 2) ..< count]))
    }
}
