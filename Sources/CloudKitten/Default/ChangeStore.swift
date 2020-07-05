//
//  ChangeStore.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 01.05.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CoreData
import CloudKit
import os.log

public class ChangeStore {
    public typealias ChangeObject = (RecordIDConvertible & PersistentHistoryCompatible & NSManagedObject)
    private let registeredTypes: [ChangeObject.Type]
    private let persistentStoreCoordinator: NSPersistentStoreCoordinator
    private let storage: StorageProvider
    private let syncTransactionAuthors: [String]
    
    private var _changesByID: [RecordID : _Change]? // cached value
    private var changesByID: [RecordID : _Change] {
        get {
            if let changesByID = _changesByID {
                // use the cached value
                return changesByID
            } else {
                let changesByID = try! loadChangesByID()
                _changesByID = changesByID
                return changesByID
            }
        }
        set {
            try! saveChangesByID(changesByID: newValue)
            _changesByID = newValue
        }
    }
    
    init(persistentStoreCoordinator: NSPersistentStoreCoordinator, changeObjectTypes: [ChangeObject.Type], storage: StorageProvider, syncTransactionAuthors: [String]) {
        self.persistentStoreCoordinator = persistentStoreCoordinator
        self.registeredTypes = changeObjectTypes
        self.storage = storage
        self.syncTransactionAuthors = syncTransactionAuthors
    }
    
    /// Use this to fetch the objects with the newest changes and then create the record
    func updatedManagedObjectIDs() -> Set<Update> {
        Set(changesByID.compactMap {
            guard case let .update(timestamp, managedObjectID) = $0.value else { return nil }
            return Update(managedObjectID: managedObjectID, timestamp: timestamp)
        })
    }
    
    /// The corresponding objects no longer exist locally
    func deletedRecordIDs() -> Set<Deletion> {
        Set(changesByID.compactMap {
            guard case let .delete(timestamp) = $0.value else { return nil }
            return Deletion(recordID: $0.key, timestamp: timestamp)
        })
    }
    
    func change(for recordID: RecordID) -> Change? {
        if let change = changesByID[recordID] {
            switch change {
            case let .update(timestamp, managedObjectID):
                return .update(Update(managedObjectID: managedObjectID, timestamp: timestamp))
            case let .delete(timestamp):
                return .deletion(Deletion(recordID: recordID, timestamp: timestamp))
            }
        }
        return nil
    }
    
    func updateChanges(context: NSManagedObjectContext) throws {
        guard context.persistentStoreCoordinator == self.persistentStoreCoordinator else {
            fatalError("The context's persistent store coordinator doesn't match")
        }
        try context.performAndWait {
            try self.processPersistentHistory(context: context)
        }
    }
    
    func remove(recordIDs: [RecordID]) {
        for recordID in recordIDs {
            changesByID[recordID] = nil
        }
    }
    
    struct Update: Hashable {
        let managedObjectID: NSManagedObjectID
        let timestamp: Date?
    }

    struct Deletion: Hashable {
        let recordID: RecordID
        let timestamp: Date?
    }
    
    enum Change {
        case update(Update)
        case deletion(Deletion)
    }
}

extension ChangeStore.Change {
    var localChange: LocalChange {
        switch self {
        case let .deletion(deletion):
            return .deleted(timestamp: deletion.timestamp)
        case let .update(update):
            return .updated(timestamp: update.timestamp, managedObjectID: update.managedObjectID)
        }
    }
}

extension ChangeStore {
    private func processPersistentHistory(context: NSManagedObjectContext) throws {
        guard let token = persistentHistoryToken else {
            os_log("No persistent history token, fetching all objects", log: .sync)
            
            let syncableObjects = try registeredTypes
                .map { $0.fetchRequest() }
                .flatMap { try context.fetch($0) }
                .compactMap { $0 as? ChangeObject }
            os_log("Successfully fetched %d syncable objects", log: .sync, type: .info, syncableObjects.count)
            
            var changesByID = [RecordID : _Change]()
            for syncableObject in syncableObjects {
                guard let recordID = syncableObject.recordID else { continue }
                changesByID[recordID] = .update(timestamp: nil, managedObjectID: syncableObject.objectID)
            }
            os_log("Successfully got %d recordIDs", log: .sync, type: .info, changesByID.count)
            
            guard let nextToken = persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: nil) else {
                fatalError("Could not get a history token from the persistent store coordinator. Is NSPersistentHistoryTracking enabled?")
            }
            
            // keep existing changes (because there might be deletions in there)
            self.changesByID.merge(changesByID) { _, new in new }
            persistentHistoryToken = nextToken
            return
        }
        
        do {
            os_log("Fetching persistent history", log: .changeTracker)
            guard let historyResult = try context.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: token)) as? NSPersistentHistoryResult else {
                os_log("Unexpected result while fetching persistent history", log: .changeTracker, type: .fault)
                fatalError("Unexpected result while fetching persistent history")
            }
            
            guard let transactions = historyResult.result as? [NSPersistentHistoryTransaction] else {
                os_log("Unexpected result while fetching persistent history", log: .changeTracker, type: .fault)
                fatalError("Unexpected result while fetching persistent history")
            }
            os_log("Successfully fetched persistent history, found %d transactions", log: .changeTracker, type: .info, transactions.count)
            
            process(transactions: transactions, context: context)
        } catch {
            guard (error as NSError).code == NSPersistentHistoryTokenExpiredError else { throw error }
            
            os_log("Persistent history token expired, setting to nil", log: .changeTracker, type: .error)
            persistentHistoryToken = nil
            // not really necessary to clean the history here, but it's cleaner
            do {
                try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: nil as Optional<NSPersistentHistoryToken>))
            } catch {
                os_log("Could not delete persistent history: %@", log: .changeTracker, type: .error, error.localizedDescription)
            }
            return try processPersistentHistory(context: context)
        }
    }
    
    private func process(transactions: [NSPersistentHistoryTransaction], context: NSManagedObjectContext) {
        guard let nextToken = transactions.last?.token else { return }
        
        var changesByID = self.changesByID// don't write to self.changesByID directly so we only write once to disk
        for transaction in transactions {
            for change in transaction.changes ?? [] {
                if change.changeType == .update, let updatedProperties = change.updatedProperties {
                    guard registeredType(for: change.changedObjectID)?.considerUpdated(updatedProperties: updatedProperties) ?? false else {
                        os_log("Ignoring change for objectID=%@", log: .sync, type: .debug, change.changedObjectID)
                        continue
                    }
                }
                
                guard let recordID = recordID(from: change, context: context) else {
                    os_log("No recordID for objectID=%@", log: .sync, type: .debug, change.changedObjectID)
                    continue
                }
                
                guard transaction.author.map({ !syncTransactionAuthors.contains($0) }) ?? true else {
                    os_log("Resetting change from sync transaction author objectID=%@", log: .sync, type: .debug, change.changedObjectID)
                    changesByID[recordID] = nil
                    continue
                }
                
                if change.changeType == .delete {
                    changesByID[recordID] = .delete(timestamp: transaction.timestamp)
                } else {
                    changesByID[recordID] = .update(timestamp: transaction.timestamp, managedObjectID: change.changedObjectID)
                }
            }
        }
        self.changesByID = changesByID
        persistentHistoryToken = nextToken
        
        os_log("There are now %d object(s) to save/delete", log: .sync, type: .debug, changesByID.count)
    }
    
    private func recordID(from change: NSPersistentHistoryChange, context: NSManagedObjectContext) -> RecordID? {
        if let object = try? context.existingObject(with: change.changedObjectID), let recordIDConvertible = object as? RecordIDConvertible, let recordID = recordIDConvertible.recordID {
            return recordID
        } else if let tombstone = change.tombstone, let recordID = registeredType(for: change.changedObjectID)?.recordID(from: tombstone) {
            return recordID
        } else {
            return nil
        }
    }
    
    private func registeredType(for objectID: NSManagedObjectID) -> ChangeObject.Type? {
        registeredTypes.first {
            guard let entityName = $0.entityName(from: objectID) else { return false }
            return $0.handlesEntity(name: entityName)
        }
    }
}

private enum _Change: Hashable, Codable {
    case update(timestamp: Date?, managedObjectID: NSManagedObjectID)
    case delete(timestamp: Date?)
    
    // MARK: Codable
    
    enum CodingKeys: CodingKey {
        case timestamp
        case managedObjectID
    }

    init(from decoder: Decoder) throws {
        guard let persistentStoreCoordinator = decoder.userInfo[.persistentStoreCoordinatorKey] as? NSPersistentStoreCoordinator else { throw NSError() }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        if let managedObjectIDURI = try? container.decode(URL.self, forKey: .managedObjectID) {
            guard let managedObjectID = persistentStoreCoordinator.managedObjectID(forURIRepresentation: managedObjectIDURI) else {
                throw DecodingError.dataCorruptedError(forKey: .managedObjectID, in: container, debugDescription: "ManagedObjectID is nil")
            }
            self = .update(timestamp: timestamp, managedObjectID: managedObjectID)
        } else {
            self = .delete(timestamp: timestamp)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .delete(timestamp):
            try container.encode(timestamp, forKey: .timestamp)
        case let .update(timestamp, managedObjectID):
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(managedObjectID.uriRepresentation(), forKey: .managedObjectID)
        }
    }
}


extension CodingUserInfoKey {
    static let persistentStoreCoordinatorKey = CodingUserInfoKey(rawValue: "persistentStoreCoordinator")!
}

// MARK: - Store on disk
extension ChangeStore {
    private static var persistentHistoryTokenKey = "persistentHistoryToken"
    private(set) var persistentHistoryToken: NSPersistentHistoryToken? {
        get {
            guard let data = try! storage.data(forKey: Self.persistentHistoryTokenKey) else { return nil }
            return try! NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
        }
        set {
            guard let newValue = newValue else {
                try! storage.store(data: nil, forKey: Self.persistentHistoryTokenKey)
                return
            }
            let data = try! NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true)
            try! storage.store(data: data, forKey: Self.persistentHistoryTokenKey)
        }
    }
    
    private static var changesByIDKey = "changesByID"
    
    private func loadChangesByID() throws -> [RecordID : _Change] {
        guard let data = try! storage.data(forKey: Self.changesByIDKey) else { return [:] }
        let decoder = JSONDecoder()
        decoder.userInfo[.persistentStoreCoordinatorKey] = persistentStoreCoordinator
        return try! decoder.decode([RecordID : _Change].self, from: data)
    }
    
    private func saveChangesByID(changesByID: [RecordID : _Change]) throws {
        let data = try! JSONEncoder().encode(changesByID)
        try! storage.store(data: data, forKey: Self.changesByIDKey)
    }
}
