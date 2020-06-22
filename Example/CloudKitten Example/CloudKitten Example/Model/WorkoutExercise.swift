//
//  WorkoutExercise.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 13.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CoreData
import CloudKit
import CloudKitten

class WorkoutExercise: NSManagedObject {
    public class func create(context: NSManagedObjectContext) -> WorkoutExercise {
        let workoutExercise = WorkoutExercise(context: context)
        workoutExercise.id = UUID()
        return workoutExercise
    }
}

// MARK: - Cloud Magic

extension WorkoutExercise {
    override func willSave() {
        super.willSave()
        
        // NOTE: this implementation is for convenience and is domain specific
        // in our case, we only have one custom zone (Workout Data Zone) and we assume that the private database is the default database
        if recordID == nil {
            guard let recordName = id?.uuidString else { return }
            if let workoutRecordID = workout?.recordID {
                // If the workout already has a recordID, copy the zone and the database scope. For example, the workout could be from the shared database
                recordID = .init(recordID: .init(recordName: recordName, zoneID: workoutRecordID.recordID.zoneID), databaseScope: workoutRecordID.databaseScope)
            } else {
                // if the workout doesn't have a recordID, then it is in the workout data zone and in the private database
                recordID = .init(recordID: .init(recordName: recordName, zoneID: WorkoutDataStorage.workoutDataZoneID), databaseScope: .private)
            }
        }
    }
}

extension WorkoutExercise: SyncableObject {
    private enum CloudKeys: String {
        case workout = "workout"
        case orderIndex = "orderIndex"
    }

    func update(with record: Record) -> RecordPullResult {
        guard let context = managedObjectContext else { fatalError("MOC is nil") }
        
        guard let id = UUID(uuidString: record.recordID.recordID.recordName) else { return .unmerged }
        self.id = id
        
        self.orderIndex = record.record[CloudKeys.orderIndex.rawValue] as? Int64 ?? 0 // nil was allowed in a previous version
        
        guard let workoutReference = record.record[CloudKeys.workout.rawValue] as? CKRecord.Reference else { return .unmerged }
        do {
            guard let workout = try Workout.existing(with: RecordID(recordID: workoutReference.recordID, databaseScope: record.databaseScope), context: context) else {
                return .missingRelationshipTargets
            }
            self.workout = workout
        } catch {
            return .error(error)
        }
        
        return .merged
    }
    
    func createRecord() -> CKRecord? {
        guard let record = systemFieldsRecord ?? emptyRecord() else { return nil }
        
        guard let workoutRecordID = self.workout?.recordID?.recordID else { return nil } // workout is required
        
        record[CloudKeys.workout.rawValue] = CKRecord.Reference(recordID: workoutRecordID, action: .deleteSelf)
        record[CloudKeys.orderIndex.rawValue] = self.orderIndex
        record.parent = CKRecord.Reference(recordID: workoutRecordID, action: .none) // parent must always have action .none
        
        assert(workoutRecordID.zoneID == record.recordID.zoneID)
        
        return record
    }
}

extension WorkoutExercise: PersistentHistoryCompatible & RecordIDConvertible {}

extension WorkoutExercise: RecordIDProperties {
    static var databaseScopePropertyName: String { "ck_databaseScope" }
    static var recordNamePropertyName: String { "ck_recordName" }
    static var zoneNamePropertyName: String { "ck_zoneName" }
    static var ownerNamePropertyName: String { "ck_ownerName" }
}

extension WorkoutExercise: SystemFieldsProperty {
    static var systemFieldsPropertyName: String { "ck_systemFields" }
}

extension WorkoutExercise: ModificationTimeFieldKey {
    static var modificationTimeFieldKey: String { "cd_modificationTime" }
}
