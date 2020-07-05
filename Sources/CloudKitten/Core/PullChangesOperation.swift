//
//  PullChangesOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 17.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import CoreData
import os.log

class PullChangesOperation: Operation {
    private let database: CKDatabase
    private let pullManager: PullManager
    private let storage: StorageProvider
    
    init(database: CKDatabase, pullManager: PullManager, storage: StorageProvider) {
        self.database = database
        self.pullManager = pullManager
        self.storage = storage
        
        self._tokens = .init(storage: storage, key: ServerChangeTokens.storageKey, default: ServerChangeTokens(databaseChangeTokens: [:], recordZoneChangeTokens: [:]))
        self._customZones = .init(storage: storage, key: CustomZones.storageKey, default: CustomZones(zoneIDs: []))
    }
    
    var pullChangesCompletionBlock: (([Error]) -> Void)?
    
    private var temporaryDatabaseChangeToken: CKServerChangeToken? // used when the database fetch operation is retried
    
    private var changedZoneIDs = [CKRecordZone.ID]()
    private var deletedZoneIDs = [CKRecordZone.ID]()
    
    private var databaseChangeErrors = [Error]()
    private var recordZoneChangeErrors = [Error]()
    
    @Stored private var tokens: ServerChangeTokens
    
    @Stored private var customZones: CustomZones
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Pulling changes for database=%@", log: .sync, database)
        queue.addOperation(makeFetchDatabaseChangesOperation(database: database))
        queue.waitUntilAllOperationsAreFinished()
        
        // Errors are either from CloudKit, or because we couldn't fetch some managedObjects. Either way don't update the token if we had any kind of errors.
        if databaseChangeErrors.isEmpty && recordZoneChangeErrors.isEmpty {
            // only save token if no errors occured!
            os_log("Successfully fetched all changes. Updating database change token.", log: .sync, type: .info)
            tokens.databaseChangeTokens[database.databaseScope] = temporaryDatabaseChangeToken
        } else {
            os_log("Could not fetch all changes, will not update database change token.\nErrors while fetching the database changes: %@\nErrors while fetching the record zone changes: %@",
                   log: .sync,
                   type: .error,
                   databaseChangeErrors.map { $0.localizedDescription },
                   recordZoneChangeErrors.map { $0.localizedDescription }
            )
        }

        pullChangesCompletionBlock?(databaseChangeErrors + recordZoneChangeErrors)
    }
}

extension PullChangesOperation {
    private func makeFetchDatabaseChangesOperation(database: CKDatabase) -> CKFetchDatabaseChangesOperation {
        let changeToken = temporaryDatabaseChangeToken ?? tokens.databaseChangeTokens[database.databaseScope]
        os_log("token=%@", log: .sync, type: .debug, changeToken ?? "nil")
        let operation = CKFetchDatabaseChangesOperation(previousServerChangeToken: changeToken)
        operation.fetchAllChanges = true

        operation.recordZoneWithIDChangedBlock = { zoneID in
            os_log("Record zone changed (zoneID=%@)", log: .sync, type: .info, zoneID)
            self.changedZoneIDs.append(zoneID)
        }

        operation.recordZoneWithIDWasDeletedBlock = { zoneID in
            os_log("Record zone was deleted (zoneID=%@)", log: .sync, type: .info, zoneID)
            // Write this zone deletion to memory
            
            // NOTE: Probably bug in CloudKit (2020/06/08)
            guard self.deletionAllowed(zoneID: zoneID, for: database.databaseScope) else {
                os_log("Ignoring (allegedly) deleted record zone (zoneID=%@, databaseScope=%@)", log: .sync, type: .error, zoneID, database.databaseScope.name)
                return
            }
            
            self.pullManager.delete(with: zoneID)
            
            self.deletedZoneIDs.append(zoneID)
        }
        
        operation.recordZoneWithIDWasPurgedBlock = { zoneID in
            os_log("Record zone was purged (zoneID=%@)", log: .sync, type: .info, zoneID)
            // Write this zone purge to memory
            
            // NOTE: Probably bug in CloudKit (2020/06/08)
            guard self.deletionAllowed(zoneID: zoneID, for: database.databaseScope) else {
                os_log("Ignoring (allegedly) purged record zone (zoneID=%@, databaseScope=%@)", log: .sync, type: .error, zoneID, database.databaseScope.name)
                return
            }
            
            self.pullManager.delete(with: zoneID)
            
            self.deletedZoneIDs.append(zoneID)
        }

        operation.changeTokenUpdatedBlock = { token in
            // Flush zone deletions for this database to disk
            // Write this new database change token to memory
            
            do {
                try self.pullManager.save()

                // reset the record zone change tokens, after the zone deletion
                for zoneID in self.deletedZoneIDs {
                    guard !self.pullManager.hasErrors(for: zoneID) else {
                        os_log("Could not save some objects. Will not update database change token.", log: .sync, type: .error)
                        self.databaseChangeErrors.append(PullError.couldNotSaveAllObjects)
                        continue
                    }
                    
                    if database.databaseScope == .private {
                        // allow the zone to be recreated again during push
                        self.customZones.zoneIDs.remove(zoneID)
                    }
                    self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID] = nil
                }
            } catch {
                os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                self.databaseChangeErrors.append(error)
            }
            
            self.temporaryDatabaseChangeToken = token
        }

        operation.fetchDatabaseChangesCompletionBlock = { (token, moreComing, error) in
            if let error = error {
                os_log("Could not fetch database changes: %@", log: .sync, type: .error, error.localizedDescription)
                
                if let retryAfter = (error as? CKError)?.retryAfterSeconds {
                    os_log("Will retry to fetch database changes in %f seconds", log: .sync, retryAfter)
                    Thread.sleep(forTimeInterval: retryAfter)
                    self.queue.addOperation(self.makeFetchDatabaseChangesOperation(database: database))
                } else if (error as? CKError)?.code == .changeTokenExpired {
                    self.pullManager.delete(with: self.database.databaseScope)
                    
                    do {
                        try self.pullManager.save()
                        
                        if self.pullManager.errors.isEmpty {
                            if database.databaseScope == .private {
                                // allow the zones to be recreated again during push
                                self.customZones.zoneIDs = []
                            }
                            
                            // reset the record zone change tokens, after the zone deletion
                            self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]] = [:]

                            self.temporaryDatabaseChangeToken = nil
                            self.tokens.databaseChangeTokens[database.databaseScope] = nil
                            
                            self.queue.addOperation(self.makeFetchDatabaseChangesOperation(database: database))
                        } else {
                            os_log("Could not save some objects. Will not update database change token.", log: .sync, type: .error)
                            self.databaseChangeErrors.append(PullError.couldNotSaveAllObjects)
                        }
                    } catch {
                        os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                        self.databaseChangeErrors.append(error)
                    }
                } else {
                    self.databaseChangeErrors.append(error)
                }
                return
            }
            
            // Flush zone deletions for this database to disk
            // Write this new database change token to memory
            
            do {
                try self.pullManager.save()

                // reset the record zone change tokens, after the zone deletion
                for zoneID in self.deletedZoneIDs {
                    guard !self.pullManager.hasErrors(for: zoneID) else {
                        os_log("Could not save some objects. Will not update database change token.", log: .sync, type: .error)
                        self.databaseChangeErrors.append(PullError.couldNotSaveAllObjects)
                        continue
                    }
                    
                    if database.databaseScope == .private {
                        // allow the zone to be recreated again during push
                        self.customZones.zoneIDs.remove(zoneID)
                    }
                    self.tokens.recordZoneChangeTokens[database.databaseScope, default: [:]][zoneID] = nil
                }
            } catch {
                os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                self.databaseChangeErrors.append(error)
            }
            
            self.temporaryDatabaseChangeToken = token
            
            if database.databaseScope == .private {
                // this prevents blindly recreating the zones during push in case they are deleted
                self.customZones.zoneIDs.formUnion(self.changedZoneIDs)
            }

            if self.changedZoneIDs.isEmpty {
                os_log("No changed record zones in database", log: .sync, type: .debug)
            } else {
                os_log("Fetching changes for %d changed record zones", log: .sync, self.changedZoneIDs.count)
                let pullRecordZoneChangesOperation = PullRecordZoneChangesOperation(database: database, zoneIDs: self.changedZoneIDs, pullManager: self.pullManager, storage: self.storage)
                pullRecordZoneChangesOperation.pullRecordZoneChangesCompletionBlock = { errors in
                    self.recordZoneChangeErrors = errors
                }
                self.queue.addOperation(pullRecordZoneChangesOperation)
            }
        }
        
        operation.database = database
        operation.qualityOfService = .userInitiated
        return operation
    }
    
    // NOTE: Probably bug in CloudKit (2020/06/08)
    private func deletionAllowed(zoneID: CKRecordZone.ID, for databaseScope: CKDatabase.Scope) -> Bool {
        switch databaseScope {
        case .private:
            return zoneID.ownerName == CKCurrentUserDefaultName
        case .shared:
            return zoneID.ownerName != CKCurrentUserDefaultName
        case .public:
            return true
        @unknown default:
            fatalError()
        }
    }
}

enum PullError: Error {
    case couldNotSaveAllObjects
    case couldNotDeleteRecordZone(zoneID: CKRecordZone.ID)
    case couldNotDeleteDatabase
    
    var localizedDescription: String {
        switch self {
        case .couldNotSaveAllObjects:
            return "Could not save all objects"
        case .couldNotDeleteRecordZone(let zoneID):
            return "Could not delete record zone (zoneID=\(zoneID)"
        case .couldNotDeleteDatabase:
            return "Could not delete database"
        }
    }
}

struct ServerChangeTokens {
    var databaseChangeTokens: [CKDatabase.Scope : CKServerChangeToken]
    var recordZoneChangeTokens: [CKDatabase.Scope : [CKRecordZone.ID : CKServerChangeToken]]
}

extension ServerChangeTokens {
    static let storageKey = "serverChangeTokens"
}

extension ServerChangeTokens: Codable {
    enum CodingKeys: CodingKey {
        case databaseChangeTokens
        case recordZoneChangeTokens
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let databaseChangeTokens = try container.decode([CKDatabase.Scope : CodableNSCoding<CKServerChangeToken>].self, forKey: .databaseChangeTokens)
        self.databaseChangeTokens = databaseChangeTokens.mapValues { $0.wrapped }
        
        let recordZoneChangeTokens = try container.decode([CKDatabase.Scope : [CodableNSCoding<CKRecordZone.ID> : CodableNSCoding<CKServerChangeToken>]].self, forKey: .recordZoneChangeTokens)
        self.recordZoneChangeTokens = recordZoneChangeTokens.mapValues { dict in
            Dictionary(uniqueKeysWithValues: dict.map { ($0.wrapped, $1.wrapped) })
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        let databaseChangeTokens = self.databaseChangeTokens.mapValues { CodableNSCoding($0) }
        try container.encode(databaseChangeTokens, forKey: .databaseChangeTokens)
        
        let recordZoneChangeTokens = self.recordZoneChangeTokens.mapValues { dict in
            Dictionary(uniqueKeysWithValues: dict.map { (CodableNSCoding($0), CodableNSCoding($1)) })
        }
        try container.encode(recordZoneChangeTokens, forKey: .recordZoneChangeTokens)
    }
}
