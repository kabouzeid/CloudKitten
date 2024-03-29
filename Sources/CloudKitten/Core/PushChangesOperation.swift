//
//  PushChangesOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 17.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import CoreData
import os.log

class PushChangesOperation: Operation {
    private let database: CKDatabase
    private let pushManager: PushManager
    private let storage: StorageProvider
    
    var pushCompletionBlock: (([Error]) -> Void)?
    
    private var errors = [Error]()
    
    init(database: CKDatabase, pushManager: PushManager, storage: StorageProvider) {
        self.database = database
        self.pushManager = pushManager
        self.storage = storage
        
        self._customZones = .init(storage: storage, key: CustomZones.storageKey, default: CustomZones(zoneIDs: []))
    }
    
    @Stored private var customZones: CustomZones
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Updating push manager", log: .sync)
        do {
            try pushManager.prepare()
        } catch {
            os_log("Could not update push manager: %@", log: .sync, type: .error, error.localizedDescription)
            return
        }
        
        let recordsToSave = pushManager.recordsToSave
        let recordIDsToDelete = pushManager.recordIDsToDelete
        os_log("Pushing %d record(s) to save and %d recordID(s) to delete into database=%@", log: .sync, recordsToSave.count, recordIDsToDelete.count, database.databaseScope.name)
        
        if database.databaseScope == .private {
            let defaultZoneID = CKRecordZone.default().zoneID
            let customZoneIDs = Set(recordsToSave.map { $0.recordID.zoneID }.filter { $0 != defaultZoneID }) // Set for uniqueness
            queue.addOperation(CreateCustomRecordZonesOperation(database: database, recordZonesToSave: customZoneIDs.map { CKRecordZone(zoneID: $0) }, storage: storage))
        }
        
        queue.addOperation(makeModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete))
        queue.waitUntilAllOperationsAreFinished()
        pushCompletionBlock?(errors)
    }
}

extension PushChangesOperation {
    private func makeModifyRecordsOperation(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID]) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
        
        operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
            if let error = error {
                if let error = error as? CKError {
                    if let retryAfter = error.retryAfterSeconds {
                        os_log("Could not modify records, will retry in %.1f second(s): %@", log: .sync, type: .error, retryAfter, error.localizedDescription)
                        Thread.sleep(forTimeInterval: retryAfter)
                        self.queue.addOperation(self.makeModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete))
                        return
                    }
                    if error.code == .limitExceeded {
                        os_log("Limit exceeded. Splitting operation in half: %@", log: .sync, type: .error, error.localizedDescription)
                        let split = self.pushManager.split(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
                        self.queue.addOperation(self.makeModifyRecordsOperation(recordsToSave: split.0.0, recordIDsToDelete: split.1.0))
                        self.queue.addOperation(self.makeModifyRecordsOperation(recordsToSave: split.0.1, recordIDsToDelete: split.1.1))
                        return
                    }
                    if error.code == .partialFailure {
                        self.errors.append(error)
                        guard let partialErrors = (error.partialErrorsByItemID as? [CKRecord.ID : Error])?.compactMapValues({ $0 as? CKError }) else {
                            fatalError("Partial failure did not contain partial errors: \(error)")
                        }
                        os_log("Could not modify records (partial failure): %@, errors=%@", log: .sync, type: .error, error.localizedDescription, partialErrors.values.map { $0.localizedDescription } )
                        self.handleZoneDeleted(errors: partialErrors)
                        self.handleServerRecordChanged(errors: partialErrors)
                        self.handleBatchRequestFailed(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, errors: partialErrors)
                        return
                    }
                }
                os_log("Could not modify records: %@", log: .sync, type: .error, error.localizedDescription)
                self.errors.append(error)
                return
            }
            
            os_log("Successfully pushed %d record(s) to save and %d recordID(s) to delete", log: .sync, type: .info, savedRecords?.count ?? 0, deletedRecordIDs?.count ?? 0)
            self.pushManager.success(savedRecords: savedRecords ?? [], deletedRecordIDs: deletedRecordIDs ?? [])
        }

        operation.isAtomic = true // note: in custom zones, operations are always atomic. the way the completion block currently handles partial failures, this should always be true though
        operation.qualityOfService = .userInitiated
        operation.database = database
        return operation
    }
    
    private func handleZoneDeleted(errors: [CKRecord.ID : CKError]) {
        let errors = errors.filter { [.zoneNotFound, .userDeletedZone].contains($0.value.code) } // can .userDeletedZone even happen here?
        let zoneIDs = Set(errors.map { $0.key.zoneID })
        for zoneID in zoneIDs {
            if self.database.databaseScope == .private {
                // make sure we only delete a zone locally if we assumed that it already existed
                // otherwise the zone should've been created at the beginning of the operation but something did go wrong...
                guard self.customZones.zoneIDs.contains(zoneID) else { return }
            }
            
            var success = true
            
            do {
                os_log("Deleting zone (zoneID=%@)", log: .sync, zoneID)
                try pushManager.delete(with: zoneID)
            } catch {
                os_log("Could not delete zone (zoneID=%@): %@", log: .sync, type: .error, zoneID, error.localizedDescription)
                success = false
            }
            
            do {
                os_log("Saving zone deletion (zoneID=%@)", log: .sync, zoneID)
                try self.pushManager.save()
            } catch {
                os_log("Could not save zone deletion (zone=%@): %@", log: .sync, type: .error, zoneID, error.localizedDescription)
                success = false
            }
            
            if self.database.databaseScope == .private {
                if success {
                    // we only want to allow to create this zone again after we successfully deleted the zone locally
                    customZones.zoneIDs.remove(zoneID)
                } else {
                    os_log("Will not remove zone from custom zones (zone=%@)", log: .sync, type: .info, zoneID)
                }
            }
        }
    }
    
    private func handleServerRecordChanged(errors: [CKRecord.ID : CKError]) {
        let errors = errors.filter { $0.value.code == .serverRecordChanged }
        for error in errors {
            self.pushManager.resolveConflict(clientRecord: error.value.clientRecord!, serverRecord: error.value.serverRecord!, ancestorRecord: error.value.ancestorRecord!)
        }
        do {
            try self.pushManager.save()
        } catch {
            os_log("Could not save resolved conflicts", log: .sync, type: .error)
        }
    }
    
    private func handleBatchRequestFailed(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID], errors: [CKRecord.ID : CKError]) {
        let errors = errors.filter { $0.value.code == .batchRequestFailed }
        guard !errors.isEmpty else { return }
        os_log("%d record(s)/recordID(s) can be retried", log: .sync, type: .debug, errors.count)
        let recordsToSaveAgain = recordsToSave.filter { errors.keys.contains($0.recordID) }
        let recordsToDeleteAgain = recordIDsToDelete.filter { errors.keys.contains($0) }
        guard !(recordsToSaveAgain.isEmpty && recordsToDeleteAgain.isEmpty) else { return }
        os_log("Will retry to push %d/%d record(s) to save and %d/%d recordID(s) to delete", log: .sync, recordsToSaveAgain.count, recordsToSave.count, recordsToDeleteAgain.count, recordIDsToDelete.count)
        self.queue.addOperation(self.makeModifyRecordsOperation(recordsToSave: recordsToSaveAgain, recordIDsToDelete: recordsToDeleteAgain))
    }
}
