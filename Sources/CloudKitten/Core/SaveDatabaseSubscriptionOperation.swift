//
//  SaveDatabaseSubscriptionOperation.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 19.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import os.log

class SaveDatabaseSubscriptionOperation: Operation {
    let database: CKDatabase
    let storage: StorageProvider
    
    var saveCompletionBlock: ((Error?) -> Void)?
    
    private var error: Error?
    
    static let databaseSubscriptionsStorageKey = "databaseSubscriptions"
    @Stored private var databaseSubscriptions: Set<CKDatabase.Scope>
    
    init(database: CKDatabase, storage: StorageProvider) {
        self.database = database
        self.storage = storage
        self._databaseSubscriptions = .init(storage: storage, key: Self.databaseSubscriptionsStorageKey, default: [])
    }
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    override func main() {
        os_log("Creating database subscription for database=%@", log: .sync, database.databaseScope.name)
        if databaseSubscriptions.contains(database.databaseScope) {
            os_log("Database subscription is assumed to already exist. Will not make a network request.", log: .sync, type: .info)
            saveCompletionBlock?(nil)
            return
        }
        
        queue.addOperation(makeSaveDatabaseSubscriptionOperation())
        queue.waitUntilAllOperationsAreFinished()
        
        saveCompletionBlock?(error)
    }
}

extension SaveDatabaseSubscriptionOperation {
    private func makeSaveDatabaseSubscriptionOperation() -> CKModifySubscriptionsOperation {
        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [makeDatabaseSubscription()], subscriptionIDsToDelete: nil)
        operation.modifySubscriptionsCompletionBlock = { _, _, error in
            if let error = error {
                if let retryAfter = (error as? CKError)?.retryAfterSeconds {
                    os_log("Could not save database subscription, will retry in %.1f second(s): %@", log: .sync, type: .error, retryAfter, error.localizedDescription)
                    Thread.sleep(forTimeInterval: retryAfter)
                    self.queue.addOperation(self.makeSaveDatabaseSubscriptionOperation())
                    return
                }
                
                os_log("Could not save database subscription: %@", log: .sync, type: .error, error.localizedDescription)
                self.error = error
                return
            }
            
            os_log("Sucessfully saved database subscription", log: .sync, type: .info)
            self.databaseSubscriptions.insert(self.database.databaseScope)
        }
        operation.qualityOfService = .userInitiated
        operation.database = database
        return operation
    }
    
    private func makeDatabaseSubscription() -> CKDatabaseSubscription {
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        let subscription = CKDatabaseSubscription(subscriptionID: "cloudkitten.db")
        subscription.notificationInfo = notificationInfo
        return subscription
    }
}
