//
//  CreateCustomRecordZonesOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 14.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import os.log

class CreateCustomRecordZonesOperation: Operation {
    let database: CKDatabase
    let recordZonesToSave: [CKRecordZone]
    let storage: StorageProvider
    
    @Stored private var customZones: CustomZones
    
    init(database: CKDatabase, recordZonesToSave: [CKRecordZone], storage: StorageProvider) {
        assert(database.databaseScope == .private, "CloudKit only supports to create custom zones in the private database")
        self.database = database
        self.recordZonesToSave = recordZonesToSave
        self.storage = storage
        self._customZones = .init(storage: storage, key: CustomZones.storageKey, default: CustomZones(zoneIDs: []))
    }
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Creating record zones %@", log: .sync, recordZonesToSave)
        if customZones.zoneIDs.isSuperset(of: recordZonesToSave.map({ $0.zoneID })) {
            // all zones assumed to be already created
            os_log("All record zones are assumed to alread exist. Will not make a network request.", log: .sync, type: .info, recordZonesToSave)
            return
        }
        
        queue.addOperation(makeCreateRecordZoneOperation(recordZonesToSave: recordZonesToSave))
        queue.waitUntilAllOperationsAreFinished()
    }
}

extension CreateCustomRecordZonesOperation {
    func makeCreateRecordZoneOperation(recordZonesToSave: [CKRecordZone]) -> CKModifyRecordZonesOperation {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: recordZonesToSave, recordZoneIDsToDelete: nil)
        operation.modifyRecordZonesCompletionBlock = { _, _, error in
            if let error = error {
                if let error = error as? CKError {
                    if let retryAfter = error.retryAfterSeconds {
                        os_log("Could not create record zones, will retry in %.1f second(s): %@", log: .sync, type: .error, retryAfter, error.localizedDescription)
                        Thread.sleep(forTimeInterval: retryAfter)
                        self.queue.addOperation(self.makeCreateRecordZoneOperation(recordZonesToSave: recordZonesToSave))
                        return
                    } else if error.code == .partialFailure {
                        guard let concreteErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecordZone.ID : Error] else {
                            fatalError("Partial failure did not contain partial errors: \(error)")
                        }
                        os_log("Could not create record zones (partial failure): %@, errors=%@", log: .sync, type: .error, error.localizedDescription, concreteErrors.values.map { $0.localizedDescription })
                        let createdZones = Set(recordZonesToSave.map { $0.zoneID }).subtracting(concreteErrors.keys)
                        os_log("Successfully created record zones are %@", log: .sync, type: .info, createdZones)
                        self.customZones.zoneIDs.formUnion(createdZones)
                        return
                    }
                }
                os_log("Could not create record zones: %@", log: .sync, type: .error, error.localizedDescription)
                return
            }
            
            os_log("Sucessfully created all record zones", log: .sync, type: .info)
            self.customZones.zoneIDs.formUnion(recordZonesToSave.map { $0.zoneID })
        }
        operation.qualityOfService = .userInitiated
        operation.database = database
        return operation
    }
}
