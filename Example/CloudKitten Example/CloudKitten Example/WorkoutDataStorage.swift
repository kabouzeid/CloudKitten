import Foundation
import CoreData
import Combine
import CloudKit
import os.log
import CloudKitten

// MARK: - Init

let coreDataLog = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Core Data")
let coreDataMonitorLog = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Core Data Monitor")

public class WorkoutDataStorage {
    public let persistentContainer: NSPersistentContainer
    
    private var subscriptions = Set<AnyCancellable>()
    
    let cloudKitten: CloudKitten
    
    static let workoutDataZoneID = CKRecordZone.ID(zoneName: "WorkoutDataZone", ownerName: CKCurrentUserDefaultName)
    
    public init() {
        // create the core data stack
        persistentContainer = NSPersistentContainer(name: "CloudKitten")
        guard let description = persistentContainer.persistentStoreDescriptions.first else { fatalError("Failed to retrieve a persistent store description.") }
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        os_log("Loading persistent store", log: coreDataLog, type: .default)
        persistentContainer.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                 
                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                os_log("Could not load persistent store: %@", log: coreDataLog, type: .fault, error.localizedDescription)
            } else {
                os_log("Successfully loaded persistent store: %@", log: coreDataLog, type: .info, storeDescription)
            }
        })
        
        let cloudKittenStorageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CloudMagic")
        cloudKitten = CloudKitten(
            container: CKContainer(identifier: "iCloud.com.kabouzeid.CloudMagic"),
            persistentContainer: persistentContainer,
            syncObjects: [Workout.self, WorkoutExercise.self],
            storage: try! FileStorageProvider(baseURL: cloudKittenStorageURL)
        )
        
        cloudKitten.subscribe(to: .private)
        cloudKitten.subscribe(to: .shared)
        
        cloudKitten.pull(from: .private)
        cloudKitten.pull(from: .shared)
        
        // optional
        cloudKitten.pullFailed(from: .private)
        cloudKitten.pullFailed(from: .shared)
        
        cloudKitten.push(to: .private)
        cloudKitten.push(to: .shared)
    }
}

#if canImport(UIKit)
import UIKit
extension WorkoutDataStorage {
    func handleNotification(with userInfo: [AnyHashable : Any], completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        return cloudKitten.handleNotification(with: userInfo, completionHandler: completionHandler)
    }
}
#endif

#if DEBUG
extension WorkoutDataStorage {
    func pull(from databaseScope: CKDatabase.Scope) {
        cloudKitten.pull(from: databaseScope)
    }
    
    func pullFailed(from databaseScope: CKDatabase.Scope) {
        cloudKitten.pullFailed(from: databaseScope)
    }
}
#endif

// MARK: - Observer

extension WorkoutDataStorage {
    static let shared: WorkoutDataStorage = {
        let stack = WorkoutDataStorage()
        
        stack.persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        
        stack.persistentContainer.viewContext.publisher
            .sink(receiveValue: WorkoutDataStorage.sendObjectsWillChange)
            .store(in: &stack.subscriptions)
        
        NotificationCenter.default.publisher(for: .NSManagedObjectContextWillSave)
            .sink { _ in os_log("Context will save notification", log: coreDataLog, type: .info) }
            .store(in: &stack.subscriptions)
        
        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .sink { _ in os_log("Context did save notification", log: coreDataLog, type: .info) }
            .store(in: &stack.subscriptions)
        
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .sink { _ in
                os_log("Persistent store remote change notification", log: coreDataLog, type: .info)
                stack.cloudKitten.push(to: .private)
                stack.cloudKitten.push(to: .shared)
            }
            .store(in: &stack.subscriptions)
        return stack
    }()
}

import os.signpost
extension WorkoutDataStorage {
    public static func sendObjectsWillChange(changes: NSManagedObjectContext.ObjectChanges) {
        for changedObject in changes.inserted.union(changes.updated).union(changes.deleted) {
            // instruments debugging
            let signPostID = OSSignpostID(log: coreDataMonitorLog)
            let signPostName: StaticString = "process single workout data change"
            os_signpost(.begin, log: coreDataMonitorLog, name: signPostName, signpostID: signPostID, "%@", changedObject.objectID)
            defer { os_signpost(.end, log: coreDataMonitorLog, name: signPostName, signpostID: signPostID) }
            //
            
            changedObject.objectWillChange.send()
            if let workout = changedObject as? Workout {
                workout.workoutExercises?.compactMap { $0 as? WorkoutExercise }
                    .forEach { workoutExercise in
                        workoutExercise.objectWillChange.send()
                }
            } else if let workoutExercise = changedObject as? WorkoutExercise {
                workoutExercise.workout?.objectWillChange.send()
            } else {
                os_log("Change for unknown NSManagedObject: %@", log: coreDataMonitorLog, type: .error, changedObject)
            }
        }
    }
}

extension NSManagedObjectContext {
    public struct ObjectChanges {
        public let inserted: Set<NSManagedObject>
        public let updated: Set<NSManagedObject>
        public let deleted: Set<NSManagedObject>
    }
    
    private static let publisher: AnyPublisher<(ObjectChanges, NSManagedObjectContext), Never> = {
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
            .compactMap { notification -> (ObjectChanges, NSManagedObjectContext)? in
                guard let userInfo = notification.userInfo else { return nil }
                guard let managedObjectContext = notification.object as? NSManagedObjectContext else { return nil }
                
                let signPostID = OSSignpostID(log: coreDataMonitorLog)
                let signPostName: StaticString = "process MOC change notification"
                os_signpost(.begin, log: coreDataMonitorLog, name: signPostName, signpostID: signPostID)
                defer { os_signpost(.end, log: coreDataMonitorLog, name: signPostName, signpostID: signPostID) }

                let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? Set()
                let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? Set()
                let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? Set()
                
                os_log("Received change notification inserted=%d updated=%d deleted=%d", log: coreDataMonitorLog, type: .debug, inserted.count, updated.count, deleted.count)
                return (ObjectChanges(inserted: inserted, updated: updated, deleted: deleted), managedObjectContext)
            }
            .share()
            .eraseToAnyPublisher()
    }()
    
    public var publisher: AnyPublisher<ObjectChanges, Never> {
        Self.publisher
            .filter { $0.1 === self } // only publish changes belonging to this context
            .map { $0.0 }
            .eraseToAnyPublisher()
    }
}

extension NSManagedObjectContext {
    func saveOrCrash() {
        if hasChanges {
            do {
                try save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }
}
