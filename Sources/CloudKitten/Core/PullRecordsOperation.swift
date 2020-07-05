//
//  PullRecordsOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 26.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import CoreData
import os.log

class PullRecordsOperation: Operation {
    private let database: CKDatabase
    private let recordDescriptions: [RecordDescription]
    private let pullManager: PullManager
    
    init(database: CKDatabase, recordDescriptions: [RecordDescription], pullManager: PullManager) {
        self.database = database
        self.recordDescriptions = recordDescriptions.filter { $0.recordID.databaseScope == database.databaseScope }
        self.pullManager = pullManager
    }
    
    var pullRecordssCompletionBlock: (([Error]) -> Void)?
    
    private var errors = [Error]()
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Pulling %d records in database=%@", log: .sync, recordDescriptions.count, database)
        queue.addOperation(makeFetchRecordsOperation(recordDescriptions: recordDescriptions))
        queue.waitUntilAllOperationsAreFinished()
    }
}

extension PullRecordsOperation {
    private func makeFetchRecordsOperation(recordDescriptions: [RecordDescription]) -> CKFetchRecordsOperation {
        let operation = CKFetchRecordsOperation(recordIDs: recordDescriptions.map { $0.recordID.recordID })
        operation.perRecordCompletionBlock = { record, recordID, error in
            if let error = error {
                if let error = error as? CKError, error.code == .unknownItem { // the record does not exist on the server (probably was deleted)
                    guard let recordID = recordID else { fatalError("recordID is unexpectedly nil") }
                    guard let recordType = recordDescriptions.first(where: { $0.recordID.recordID == recordID })?.recordType else { fatalError("Unexpected recordID") }
                    
                    self.pullManager.deleteManagedObject(recordID: recordID, recordType: recordType)
                } else {
                    os_log("Could not fetch record recordID=%@: %@", log: .sync, type: .error, recordID ?? "nil", error.localizedDescription)
                }
            } else {
                guard let record = record else { return }
                self.pullManager.updateManagedObject(record: record)
            }
        }
        
        operation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            self.pullManager.updateManagedObjectsWithMissingRelationshipTargets()
            self.pullManager.handleManagedObjectsWithMissingRelationshipTargets()
            
            do {
                os_log("Trying to save context", log: .sync)
                try self.pullManager.save()
            } catch {
                os_log("Could not save pull manager: %@", log: .sync, type: .error, error.localizedDescription)
                self.errors.append(error)
            }
            
            if let error = error {
                if (error as? CKError)?.code != .partialFailure { // partial failure is allowed (deleted records)
                    if let error = error as? CKError, let retryAfter = error.retryAfterSeconds {
                        os_log("Will retry to fetch records in %d seconds", log: .sync, retryAfter)
                        Thread.sleep(forTimeInterval: retryAfter)
                        self.queue.addOperation(self.makeFetchRecordsOperation(recordDescriptions: recordDescriptions))
                        os_log("Could not fetch records: %@", log: .sync, type: .error, error.localizedDescription)
                        return
                    } else {
                        os_log("Could not fetch records: %@", log: .sync, type: .error, error.localizedDescription)
                        self.errors.append(error)
                    }
                }
            }
            
            self.pullRecordssCompletionBlock?(self.pullManager.errors + self.errors)
        }
        
        operation.database = database
        return operation
    }
}
