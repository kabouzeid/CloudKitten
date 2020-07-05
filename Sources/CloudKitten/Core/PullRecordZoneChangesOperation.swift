//
//  PullRecordZoneChangesOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 23.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CoreData
import CloudKit
import os.log

class PullRecordZoneChangesOperation: Operation {
    private let database: CKDatabase
    private let zoneIDs: [CKRecordZone.ID]
    private let storage: StorageProvider
    private let pullManager: PullManager
    
    var pullRecordZoneChangesCompletionBlock: (([Error]) -> Void)?
    
    init(database: CKDatabase, zoneIDs: [CKRecordZone.ID], pullManager: PullManager, storage: StorageProvider) {
        self.database = database
        self.zoneIDs = zoneIDs
        self.pullManager = pullManager
        self.storage = storage
        
        self._tokens = .init(storage: storage, key: ServerChangeTokens.storageKey, default: ServerChangeTokens(databaseChangeTokens: [:], recordZoneChangeTokens: [:]))
        self._customZones = .init(storage: storage, key: CustomZones.storageKey, default: CustomZones(zoneIDs: []))
    }
    
    private var errors = [Error]()
    
    @Stored private var tokens: ServerChangeTokens
    
    @Stored private var customZones: CustomZones
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Fetching record zone changes for zoneIDs=%@ in database=%@", log: .sync, zoneIDs, database.databaseScope.name)
        queue.addOperation(makeFetchRecordZoneChangesOperation(database: database, zoneIDs: zoneIDs))
        queue.waitUntilAllOperationsAreFinished()
        
        self.pullRecordZoneChangesCompletionBlock?(self.pullManager.recordErrors.values + self.errors)
    }
}

extension PullRecordZoneChangesOperation {
    private func makeFetchRecordZoneChangesOperation(database: CKDatabase, zoneIDs: [CKRecordZone.ID]) -> CKFetchRecordZoneChangesOperation {
        var configurationsByRecordZoneID = [CKRecordZone.ID : CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for zoneID in zoneIDs {
            configurationsByRecordZoneID[zoneID] = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID],
                resultsLimit: nil,
                desiredKeys: nil
            )
        }
        os_log("Fetch record zone changes, configurations=%@", log: .sync, configurationsByRecordZoneID)
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIDs, configurationsByRecordZoneID: configurationsByRecordZoneID)
        operation.fetchAllChanges = true
        
        operation.recordChangedBlock = { record in
            // Write this record change to memory
            
            self.pullManager.updateManagedObject(record: record)
        }
        
        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            // Write this record deletion to memory
            
            self.pullManager.deleteManagedObject(recordID: recordID, recordType: recordType)
        }
        
        operation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, _ in
            os_log("recordZoneChangeTokensUpdatedBlock zoneID=%@, token=%@", log: .sync, zoneID, token ?? "nil")
            // Flush record changes and deletions for this zone to disk
            // Write this new zone change token to disk
            
            self.pullManager.updateManagedObjectsWithMissingRelationshipTargets(in: zoneID)
            guard !self.pullManager.hasManagedObjectsWithMissingRelationshipTargets(in: zoneID) else {
                os_log("Will not attempt to save context & update record zone change token for zoneID=%@ because there are still objects with missing relationship targets", log: .sync, zoneID)
                return
            }
            
            do {
                os_log("Trying to save context", log: .sync)
                try self.pullManager.save()
                
                if !self.pullManager.recordErrors.contains(where: { $0.key.recordID.recordID.zoneID == zoneID }) {
                    os_log("Updating record zone change token for zoneID=%@ token=%@", log: .sync, type: .debug, zoneID, token ?? "nil")
                    self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID] = token
                } else {
                    os_log("Will not update record zone change token for zoneID=%@", log: .sync, type: .info, zoneID)
                }
            } catch {
                os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                self.errors.append(error)
            }
        }
        
        operation.recordZoneFetchCompletionBlock = { (zoneID, token, _, _, error) in
            os_log("recordZoneFetchCompletionBlock zoneID=%@ token=%@ error=%@", log: .sync, zoneID, token ?? "nil", error?.localizedDescription ?? "nil")
            // Flush record changes and deletions for this zone to disk
            // Write this new zone change token to disk
            
            self.pullManager.updateManagedObjectsWithMissingRelationshipTargets(in: zoneID)
            self.pullManager.handleManagedObjectsWithMissingRelationshipTargets(in: zoneID)
            
            if let error = error {
                if let error = error as? CKError {
                    let recreated = error.code == .userDeletedZone || error.code == .changeTokenExpired
                    let deleted = error.code == .zoneNotFound && (self.database.databaseScope != .private || self.customZones.zoneIDs.contains(zoneID))
                    if recreated || deleted {
                        if recreated {
                            os_log("Could not fetch zone changes for zoneID=%@. Deleting local data for zone and fetching zone again with nil token. %@", log: .sync, zoneID, error.localizedDescription)
                        }
                        if deleted {
                            os_log("Zone with zoneID=%@ does not exist on server. Deleting local data for zone. %@", log: .sync, zoneID, error.localizedDescription)
                        }
                        
                        self.pullManager.delete(with: zoneID)
                        
                        do {
                            os_log("Trying to save context", log: .sync)
                            if try self.pullManager.save() {
                                if !self.pullManager.recordErrors.contains(where: { $0.key.recordID.recordID.zoneID == zoneID }) {
                                    if self.database.databaseScope == .private && deleted {
                                        self.customZones.zoneIDs.remove(zoneID)
                                    }
                                    os_log("Resetting record zone change token for zoneID=%@", log: .sync, type: .debug, zoneID)
                                    self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID] = nil
                                    if recreated {
                                        self.queue.addOperation(self.makeFetchRecordZoneChangesOperation(database: database, zoneIDs: [zoneID]))
                                    }
                                } else {
                                    os_log("Will not update record zone change token for zoneID=%@", log: .sync, type: .info, zoneID)
                                }
                            } else {
                                os_log("Could not save some objects. Will not update database change token.", log: .sync, type: .error)
                                self.errors.append(NSError(domain: String(describing: Self.self), code: 0, userInfo: [NSLocalizedDescriptionKey : "Could not save some objects. Will not update database change token."]))
                            }
                        } catch {
                            os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                            self.errors.append(error)
                        }
                        return
                    }
                }
                // do not attempt retry here, we will finish processing the changes for the other zones and then retry in the final completion block
                os_log("Could not fetch zone changes for zoneID=%@, will not attempt to save changes or update token: %@", log: .sync, zoneID, error.localizedDescription)
                self.errors.append(error)
                
                // continue though...
            }
            
            do {
                os_log("Trying to save context", log: .sync)
                try self.pullManager.save()
                
                if (error == nil && !self.pullManager.recordErrors.contains(where: { $0.key.recordID.recordID.zoneID == zoneID })) {
                    os_log("Updating record zone change token for zoneID=%@ token=%@", log: .sync, type: .debug, zoneID, token ?? "nil")
                    self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID] = token
                } else {
                    os_log("Will not update record zone change token for zoneID=%@", log: .sync, type: .info, zoneID)
                }
            } catch {
                os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                self.errors.append(error)
            }
        }
        
        operation.fetchRecordZoneChangesCompletionBlock = { error in
            if let error = error {
                os_log("Could not fetch all changes for all record zones in database=%@: %@", log: .sync, database.databaseScope.name, error.localizedDescription)
                
                if let retryAfter = (error as? CKError)?.retryAfterSeconds {
                    os_log("Will retry to fetch record zone changes in %d seconds", log: .sync, retryAfter)
                    Thread.sleep(forTimeInterval: retryAfter)
                    self.queue.addOperation(self.makeFetchRecordZoneChangesOperation(database: database, zoneIDs: zoneIDs))
                    return
                } else {
                    os_log("Will not retry to fetch record zone changes", log: .sync, type: .info)
                    self.errors.append(error)
                }
            }
        }
        
        operation.database = database
        operation.qualityOfService = .userInitiated
        return operation
    }
}

