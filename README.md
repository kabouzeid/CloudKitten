# CloudKitten

CloudKitten is a Swift package, to use it in your project, add this to your `Package.swift` file:

```swift
let package = Package(
    ...
    dependencies: [
        .package(url: "https://github.com/kabouzeid/CloudKitten.git", from: "0.1.0")
    ],
    ...
)
```

## Core Data

Add `SyncableObject` conformance to all `NSManagedObject` subclasses you wish to sync.
Conforming to `RecordIDProperties`, `SystemFieldsProperty` and `ModificationTimeFieldKey` provides you with default implementations for most of the requirements in `SyncableObject`. In this case you need to the following attributes to your Core Data entity.

| Attribute Name     | Attribute Type |
|--------------------|----------------|
| `ck_databaseScope` | Integer 16     |
| `ck_recordName`    | String         |
| `ck_zoneName`      | String         |
| `ck_ownerName`     | String         |
| `ck_systemFields`  | Binary Data    |

```swift
class Foo: NSManagedObject {
    ...
}

extension Foo: SyncableObject {
    func update(with record: Record) -> RecordPullResult {
        guard let id = UUID(uuidString: record.recordID.recordID.recordName) else { return .unmerged }
        self.id = id
        
        guard let someDateValue = record.record["someDateValue"] as? Date else { return .unmerged }
        self.someDateValue = someDateValue
        
        guard let someStringValue = record.record["someStringValue"] as? String else { return .unmerged }
        self.someStringValue = someStringValue
        
        return .merged
    }
    
    func createRecord() -> CKRecord? {
        guard let record = systemFieldsRecord ?? emptyRecord() else { return nil }

        guard let someDateValue = self.someDateValue else { return nil }
        guard let someStringValue = self.someStringValue else { return nil }
        
        record["someDateValue"] = someDateValue
        record["someStringValue"] = someStringValue
        
        return record
    }
}

extension Foo: PersistentHistoryCompatible & RecordIDConvertible {}

// NSManagedObject Field
extension Foo: RecordIDProperties {
    static var databaseScopePropertyName: String { "ck_databaseScope" }
    static var recordNamePropertyName: String { "ck_recordName" }
    static var zoneNamePropertyName: String { "ck_zoneName" }
    static var ownerNamePropertyName: String { "ck_ownerName" }
}

// NSManagedObject Field
extension Foo: SystemFieldsProperty {
    static var systemFieldsPropertyName: String { "ck_systemFields" }
}

// CKRecord Field
extension Foo: ModificationTimeFieldKey {
    static var modificationTimeFieldKey: String { "cd_modificationTime" }
}
```

A particular object is only synced when it's recordID property is set, which tells CloudKitten with which record this object should be synced.
One possibility is to set the `recordID` automatically during the `NSManagedObjectContext`'s save.

```swift
extension Foo {
    override func willSave() {
        super.willSave()
        if recordID == nil {
            guard let recordName = self.id?.uuidString else { return }
            recordID = RecordID(recordID: CKRecord.ID(recordName: recordName, zoneID: myZoneID), databaseScope: .private)
        }
    }
}
```

When you have prepared your `NSManagedObject` subclasses, create  a `CloudKitten` instance using the convenience initializer for Core Data.
Here you pass in your  `NSManagedObject` subclasses (e.g. `Foo.self`, `Bar.self`).
This uses `NSPersistentHistoryTracking` to keep track of your local changes.

```swift
let cloudKittenStorageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CloudKitten")
cloudKitten = CloudKitten(
    container: CKContainer(identifier: "iCloud.com.foo.bar"),
    persistentContainer: persistentContainer,
    syncObjects: [Foo.self, Bar.self],
    storage: try! FileStorageProvider(baseURL: cloudKittenStorageURL)
)
```

### Sync

```swift
// fetch & merge changes (last writer wins merge, updates tokens, etc.)
cloudKitten.pull(from: .private)
cloudKitten.pull(from: .shared)

// optional, retry to pull unmerged records (e.g. useful after an app update)
cloudKitten.pullFailed(from: .private)
cloudKitten.pullFailed(from: .shared)

// push local changes
cloudKitten.push(to: .private)
cloudKitten.push(to: .shared)
```

### Subscribing to changes
```swift
// subscribe to database notifications (CloudKitten only performs those once)
cloudKitten.subscribe(to: .private)
cloudKitten.subscribe(to: .shared)
```

```swift
@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    
    ...
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        _ = WorkoutDataStorage.shared.handleNotification(with: userInfo, completionHandler: completionHandler)
    }
}
```
