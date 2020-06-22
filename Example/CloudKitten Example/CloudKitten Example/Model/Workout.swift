//
//  Workout.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 13.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CoreData
import CloudKit
import CloudKitten

class Workout: NSManagedObject {
    public class func create(context: NSManagedObjectContext) -> Workout {
        let workout = Workout(context: context)
        workout.id = UUID()
        return workout
    }
}

extension Workout {
    var workoutExerciseArray: [WorkoutExercise]? {
        get {
            workoutExercises?
                .compactMap { $0 as? WorkoutExercise }
                .sorted(by: { $0.orderIndex < $1.orderIndex })
        }
        set {
            newValue?.enumerated().forEach { $0.element.orderIndex = Int64($0.offset) }
            workoutExercises = newValue.map { NSSet(array: $0) }
        }
    }
}

// MARK: - Cloud Magic

extension Workout {
    override func willSave() {
        super.willSave()
        
        // NOTE: this implementation is for convenience and is domain specific
        // in our case, we only have one custom zone (Workout Data Zone) and we assume that the private database is the default database
        if recordID == nil {
            guard let recordName = id?.uuidString else { return }
            recordID = .init(recordID: .init(recordName: recordName, zoneID: WorkoutDataStorage.workoutDataZoneID), databaseScope: .private)
        }
    }
}

extension Workout: SyncableObject {
    private enum CloudKeys: String {
        case start = "start"
    }
    
    func update(with record: Record) -> RecordPullResult {
        guard let id = UUID(uuidString: record.recordID.recordID.recordName) else { return .unmerged }
        self.id = id
        
        guard let start = record.record[CloudKeys.start.rawValue] as? Date else { return .unmerged }
        self.start = start
        
        return .merged
    }
    
    func createRecord() -> CKRecord? {
        guard let record = systemFieldsRecord ?? emptyRecord() else { return nil }

        guard let start = self.start else { return nil } // start is required
        
        record[CloudKeys.start.rawValue] = start
        
        return record
    }
}

extension Workout: PersistentHistoryCompatible & RecordIDConvertible {}

extension Workout: RecordIDProperties {
    static var databaseScopePropertyName: String { "ck_databaseScope" }
    static var recordNamePropertyName: String { "ck_recordName" }
    static var zoneNamePropertyName: String { "ck_zoneName" }
    static var ownerNamePropertyName: String { "ck_ownerName" }
}

extension Workout: SystemFieldsProperty {
    static var systemFieldsPropertyName: String { "ck_systemFields" }
}

extension Workout: ModificationTimeFieldKey {
    static var modificationTimeFieldKey: String { "cd_modificationTime" }
}
