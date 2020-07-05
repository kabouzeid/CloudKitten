//
//  CloudKitten.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 16.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CloudKit
import os.log

// MARK: - Persistent History

public class CloudKitten {
    public let container: CKContainer
    
    public let storage: StorageProvider
    
    public typealias PushManagerFactory = (CKDatabase.Scope) -> PushManager
    public typealias PullManagerFactory = (CKDatabase.Scope) -> PullManager
    
    private let pushManagerFactory: PushManagerFactory
    private let pullManagerFactory: PullManagerFactory
    
    /// - Parameters:
    ///   - persistentContainer: `NSPersistentHistoryTrackingKey` and `NSPersistentStoreRemoteChangeNotificationPostOptionKey` must be set to true on the persistent store descriptions that should be synced.
    ///   - customZoneIDs: The custom zones to create and subscribe to if necessary.
    public init(container: CKContainer, pushManagerFactory: @escaping PushManagerFactory, pullManagerFactory: @escaping PullManagerFactory, storage: StorageProvider) {
        self.container = container
        
        self.pushManagerFactory = pushManagerFactory
        self.pullManagerFactory = pullManagerFactory
        
        self.storage = storage
    }
    
    private let cloudQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
}

import CoreData
extension CloudKitten {
    public convenience init(container: CKContainer, persistentContainer: NSPersistentContainer, syncObjects: [(PushManager.PushObject & PullManager.PullObject & ChangeStore.ChangeObject).Type], storage: StorageProvider) {
        let pushContextName = "CloudKitten.push"
        let pullContextName = "CloudKitten.pull"
        let changeStore = ChangeStore(persistentStoreCoordinator: persistentContainer.persistentStoreCoordinator, changeObjectTypes: syncObjects, storage: storage, syncTransactionAuthors: [pushContextName, pullContextName])
        self.init(
            container: container,
            pushManagerFactory: { databaseScope in
                let context = persistentContainer.newBackgroundContext()
                context.transactionAuthor = pushContextName
                return PushManager(pushObjectTypes: syncObjects, context: context, changeStore: changeStore, databaseScope: databaseScope)
            },
            pullManagerFactory: { databaseScope in
                let context = persistentContainer.newBackgroundContext()
                context.transactionAuthor = pullContextName
                return PullManager(pullObjectTypes: syncObjects, context: context, changeStore: changeStore, storage: storage, databaseScope: databaseScope)
            },
            storage: storage
        )
    }
}

// MARK: - Public API

extension CloudKitten {
    public func pull(from databaseScope: CKDatabase.Scope, completion: (([Error]) -> Void)? = nil) {
        os_log("Enqueuing pull from %@", log: .sync, databaseScope.name)
        cloudQueue.addOperation {
            let operation = PullChangesOperation(database: self.container.database(with: databaseScope), pullManager: self.pullManagerFactory(databaseScope), storage: self.storage)
            operation.pullChangesCompletionBlock = { errors in
                if errors.isEmpty {
                    os_log("Pull was successful", log: .sync, type: .info)
                } else {
                    os_log("Pull was not successful, errors=%@", log: .sync, type: .error, errors.map { $0.localizedDescription })
                }
                completion?(errors)
            }
            operation.main()
        }
    }
    
    public func pullFailed(from databaseScope: CKDatabase.Scope, completion: (([Error]) -> Void)? = nil) {
        os_log("Enqueuing pull (failed records) from %@", log: .sync, databaseScope.name)
        cloudQueue.addOperation {
            let pullManager = self.pullManagerFactory(databaseScope)
            let operation = PullRecordsOperation(database: self.container.database(with: databaseScope), recordDescriptions: Array(pullManager.failedRecords), pullManager: pullManager)
            operation.pullRecordssCompletionBlock = { errors in
                if errors.isEmpty {
                    os_log("Pull (failed) was successful", log: .sync, type: .info)
                } else {
                    os_log("Pull (failed) was not successful, errors=%@", log: .sync, type: .error, errors.map { $0.localizedDescription })
                }
                completion?(errors)
            }
            operation.main()
        }
    }
    
    /// It's recommended to use `sync(with:)` instead
    public func push(to databaseScope: CKDatabase.Scope, completion: (([Error]) -> Void)? = nil) {
        os_log("Enqueuing push to %@", log: .sync, databaseScope.name)
        cloudQueue.addOperation {
            let operation = PushChangesOperation(database: self.container.database(with: databaseScope), pushManager: self.pushManagerFactory(databaseScope), storage: self.storage)
            operation.pushCompletionBlock = { errors in
                if errors.isEmpty {
                    os_log("Push was successful", log: .sync, type: .info)
                } else {
                    os_log("Push was not successful, errors=%@", log: .sync, type: .error, errors.map { $0.localizedDescription })
                }
                completion?(errors)
            }
            operation.main()
        }
    }
    
    public func subscribe(to databaseScope: CKDatabase.Scope, completion: ((Error?) -> Void)? = nil) {
        os_log("Enqueuing subscribe to %@", log: .sync, databaseScope.name)
        cloudQueue.addOperation {
            let operation = SaveDatabaseSubscriptionOperation(database: self.container.database(with: databaseScope), storage: self.storage)
            operation.saveCompletionBlock = { error in
                if let error = error {
                    os_log("Subscribing to database was not successful: %@", log: .sync, type: .error, error.localizedDescription)
                } else {
                    os_log("Subscribing to database was successful", log: .sync, type: .info)
                }
                completion?(error)
            }
            operation.main()
        }
    }
}

#if canImport(UIKit)
import UIKit
extension CloudKitten {
    public func handleNotification(with userInfo: [AnyHashable : Any], completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("Not a CKNotification", log: .sync, type: .info)
            return false
        }
        switch notification.notificationType {
        case .database:
            guard let databaseNotification = CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) else {
                os_log("Could not create CKDatabaseNotification eventhough notificationType=database", log: .sync, type: .error)
                return false
            }
            pull(from: databaseNotification.databaseScope) { errors in
                completionHandler(errors.isEmpty ? .newData : .failed)
            }
            return true
        case .recordZone:
            guard let recordZoneNotification = CKRecordZoneNotification(fromRemoteNotificationDictionary: userInfo) else {
                os_log("Could not create CKRecordZoneNotification eventhough notificationType=recordZone", log: .sync, type: .error)
                return false
            }
            if let _ = recordZoneNotification.recordZoneID {
                // NOTE: for now just fetch all database changes, maybe change this in future
                pull(from: recordZoneNotification.databaseScope) { errors in
                    completionHandler(errors.isEmpty ? .newData : .failed)
                }
            } else {
                pull(from: recordZoneNotification.databaseScope) { errors in
                    completionHandler(errors.isEmpty ? .newData : .failed)
                }
            }
            return true
        default:
            return false
        }
    }
}
#endif
