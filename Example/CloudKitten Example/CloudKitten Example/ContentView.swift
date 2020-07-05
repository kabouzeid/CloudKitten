//
//  ContentView.swift
//  iOS Example
//
//  Created by Karim Abou Zeid on 21.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import SwiftUI
import CoreData
import CloudKit
import CloudKitten

private let dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .medium
    return dateFormatter
}()

@discardableResult private func createWorkout(in context: NSManagedObjectContext) -> Workout {
    let workout = Workout(context: context)
    workout.id = UUID()
    workout.start = Date()
    
    for _ in 0..<5 {
        let workoutExercise = WorkoutExercise.create(context: context)
        workout.workoutExerciseArray!.append(workoutExercise)
    }
    
    return workout
}

struct ContentView: View {
    @Environment(\.managedObjectContext)
    var viewContext
 
    var body: some View {
        NavigationView {
            MasterView()
                .navigationBarTitle(Text("Master"))
                .navigationBarItems(
                    leading: EditButton(),
                    trailing: Button(
                        action: {
                            withAnimation {
                                createWorkout(in: self.viewContext)
                                self.viewContext.saveOrCrash()
                            }
                        }
                    ) {
                        Image(systemName: "plus")
                    }
                )
            Text("Detail view content goes here")
                .navigationBarTitle(Text("Detail"))
        }.navigationViewStyle(DoubleColumnNavigationViewStyle())
    }
}

extension Workout {
    var databaseScope: CKDatabase.Scope? {
        CKDatabase.Scope(rawValue: Int(ck_databaseScope))
    }
}

/*
 +---------------------+------------------------+-------------------------------+
 |                     | scope == .private      | scope == .shared              |
 +---------------------+------------------------+-------------------------------+
 | record.share != nil | shared by current user | shared from other user        |
 +---------------------+------------------------+-------------------------------+
 | record.share == nil | not shared             | shared parent from other user |
 +---------------------+------------------------+-------------------------------+
 */
extension Workout {
    var shareStatus: ShareStatus {
        if databaseScope == .private, systemFieldsRecord?.share != nil {
            return .sharedByCurrentUser
        } else if databaseScope == .shared, systemFieldsRecord?.share != nil {
            return .sharedByOtherUser
        }
        return .none
    }
    
    enum ShareStatus {
        case none
        case sharedByCurrentUser
        case sharedByOtherUser
    }
}

struct MasterView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Workout.start, ascending: true)],
        animation: .default)
    var workouts: FetchedResults<Workout>

    @Environment(\.managedObjectContext)
    var viewContext
    
    func shareStatusIcon(shareStatus: Workout.ShareStatus) -> Image? {
        switch shareStatus {
        case .none:
            return nil
        case .sharedByCurrentUser, .sharedByOtherUser:
            return Image(systemName: "person.crop.circle")
        }
    }

    var body: some View {
        VStack {
            Button("Clear All") {
                self.workouts.forEach {
                    self.viewContext.delete($0)
                }
                self.viewContext.saveOrCrash()
            }
            Button("Batch Clear All") {
                try! self.viewContext.execute(NSBatchDeleteRequest(fetchRequest: Workout.fetchRequest()))
            }
//            Button("Background Insert") {
//                WorkoutDataStorage.shared.persistentContainer.performBackgroundTask { context in
//                    createWorkout(in: context)
//                    context.saveOrCrash()
//                }
//            }
//            Button("Batch Insert") {
//                let request = NSBatchInsertRequest(entity: Workout.entity(), objects: (1...5).map { _ in ["id" : UUID(), "start" : Date()] })
//                try! self.viewContext.execute(request)
//            }
            Button("Persistent History") {
                let token: NSPersistentHistoryToken? = nil
                do {
                    let history = try WorkoutDataStorage.shared.persistentContainer.viewContext.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: token))
                    print(history)
                } catch {
                    print(error)
                }
            }
            Button("Pull (private, shared)") {
                WorkoutDataStorage.shared.pull(from: .private)
                WorkoutDataStorage.shared.pull(from: .shared)
            }
            Button("Pull failed (private, shared)") {
                WorkoutDataStorage.shared.pullFailed(from: .private)
                WorkoutDataStorage.shared.pullFailed(from: .shared)
            }
            
            Button("Delete WorkoutDataZone") {
                let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [WorkoutDataStorage.workoutDataZoneID])
                operation.modifyRecordZonesCompletionBlock = { _, _, error in
                    print("zone deletion result: \(error?.localizedDescription ?? "nil")")
                }
                WorkoutDataStorage.shared.cloudKitten.container.privateCloudDatabase.add(operation)
            }
            
//            Button("Send Full") {
//                let zoneID = CKRecordZone.ID(zoneName: "WorkoutDataZone", ownerName: CKCurrentUserDefaultName)
//                let record = CKRecord(recordType: "Workout", recordID: .init(recordName: "testrec", zoneID: zoneID))
//                record["start"] = Date()
//                print("start1: \(record["start"])")
//
//                let container = CKContainer(identifier: "iCloud.com.kabouzeid.CloudMagic")
//                container.privateCloudDatabase.save(record) { (rec, err) in
//                    print("saved1: record=\(rec) error=\(err)")
//
//                    let data = rec!.encdodedSystemFields
//                    let record = CKRecord(archivedData: data)!
//                    print("start2: \(record["start"])")
////                    record["start"] = nil
//
//                    container.privateCloudDatabase.save(record) { (rec, err) in
//                        print("saved2: record=\(rec) error=\(err)")
//                    }
//                }
//            }
            
            List {
                ForEach(workouts, id: \.self) { workout in
                    NavigationLink(
                        destination: DetailView(workout: workout)
                    ) {
                        HStack {
                            Text("\(workout.start!, formatter: dateFormatter)")
                            Spacer()
                            self.shareStatusIcon(shareStatus: workout.shareStatus).map { icon in
                                icon.foregroundColor(.secondary)
                            }
                        }
                    }
                }.onDelete { indices in
                    let workouts = self.workouts
                    for index in indices {
                        let workout = workouts[index]
                        if workout.shareStatus == .sharedByOtherUser {
                            print("Trying to delete shared workout")
                            guard let shareReference = workout.systemFieldsRecord?.share else {
                                print("Workout has no share reference, aborting")
                                continue
                            }
                            let container = WorkoutDataStorage.shared.cloudKitten.container
                            print("Deleting recordID=\(shareReference.recordID)")
                            container.sharedCloudDatabase.delete(withRecordID: shareReference.recordID) { deletedRecord, error in
                                // seems like notifications are not fired
                                // NOTE: pull even on error, it could be possible that the share was already deleted before
                                WorkoutDataStorage.shared.pull(from: .shared)
                                
                                if let error = error {
                                    print("Could not delete record with recordID=\(shareReference.recordID): \(error.localizedDescription)")
                                    return
                                }
                                print("Successfully deleted record: \(deletedRecord?.description ?? "nil")")
                            }
                        } else {
                            self.viewContext.delete(workout)
                        }
                    }
                    self.viewContext.saveOrCrash()
                }
            }
        }
    }
}

struct DetailView: View {
    @ObservedObject var workout: Workout
    
    private var workoutStart: Binding<Date> {
        Binding(
            get: {
                self.workout.start!
            },
            set: { newValue in
                self.workout.start = newValue
            }
        )
    }

    var body: some View {
        VStack {
            if workout.start != nil {
                DatePicker("start", selection: workoutStart, displayedComponents: .date)
                    .labelsHidden()
            }
            
            Button("Save changes") {
                self.workout.managedObjectContext?.saveOrCrash()
            }
            
            List {
                ForEach(workout.workoutExerciseArray ?? [], id: \.objectID) { workoutExercise in
                    HStack {
                        Text("\(workoutExercise.id?.description ?? "nil")").lineLimit(1)
                        Spacer()
                        Text("\(workoutExercise.orderIndex)").bold()
                    }
                }
                .onMove { (offsets, to) in
                    self.workout.workoutExerciseArray?.move(fromOffsets: offsets, toOffset: to)
                    try! self.workout.managedObjectContext?.save()
                }
                .onDelete { offsets in
                    guard let workoutExercises = self.workout.workoutExerciseArray else { return }
                    for index in offsets {
                        self.workout.managedObjectContext?.delete(workoutExercises[index])
                    }
                    self.workout.managedObjectContext?.saveOrCrash()
                }
                
                Button("New") {
                    guard let context = self.workout.managedObjectContext else { return }
                    let workoutExercise = WorkoutExercise.create(context: context)
                    self.workout.workoutExerciseArray!.append(workoutExercise)
                    context.saveOrCrash()
                }
            }
        }
        .navigationBarTitle(Text("Detail"))
        .navigationBarItems(trailing: HStack(spacing: 16) {
            // hack: wrap with Image for proper sizing
            Image(systemName: "person").hidden().background(
                WorkoutCloudKitSharingButton(workout: self.workout)
            )
            EditButton()
        })
    }
}

struct WorkoutCloudKitSharingButton: UIViewRepresentable {
    typealias UIViewType = UIButton

    let workout: Workout

    func makeUIView(context: UIViewRepresentableContext<WorkoutCloudKitSharingButton>) -> UIButton {
        let button = UIButton()
        updateUIView(button, context: context)
        button.addTarget(context.coordinator, action: #selector(context.coordinator.pressed(_:)), for: .touchUpInside)

        context.coordinator.button = button
        return button
    }

    func updateUIView(_ button: UIButton, context: UIViewRepresentableContext<WorkoutCloudKitSharingButton>) {
        switch workout.shareStatus {
        case .none:
            button.titleLabel?.text = "Add People"
            button.setImage(UIImage(systemName: "person.crop.circle.badge.plus"), for: .normal)
        case .sharedByCurrentUser, .sharedByOtherUser:
            button.titleLabel?.text = "Manage People"
            button.setImage(UIImage(systemName: "person.crop.circle.badge.checkmark"), for: .normal)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var button: UIButton?

        var parent: WorkoutCloudKitSharingButton

        init(_ parent: WorkoutCloudKitSharingButton) {
            self.parent = parent
        }

        @objc func pressed(_ sender: UIButton) {
            guard self.parent.workout.systemFieldsRecord != nil else {
                print("sharing of record that was not uploaded before is not yet supported")
                return
            }
            guard let rootRecord = self.parent.workout.createRecord() else { fatalError() }
            
            if let shareReference = rootRecord.share {
                let container = WorkoutDataStorage.shared.cloudKitten.container
                guard let databaseScope = self.parent.workout.databaseScope else { fatalError("no db scope") }
                let database = databaseScope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
                database.fetch(withRecordID: shareReference.recordID) { share, error in
                    if let error = error {
                        print("Could not fetch share record with recordID=\(shareReference.recordID): \(error.localizedDescription)")
                        return
                    }
                    guard let share = share as? CKShare else {
                        print("Error: share record is nil or not a CKShare")
                        return
                    }
                    print("Successfully fetched share record: \(share.description)")
                    DispatchQueue.main.async {
                        self.editShareController(share: share, container: container)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    guard self.parent.workout.databaseScope == .private else { fatalError() }
                    self.createShareController(rootRecord: rootRecord)
                }
            }
        }
        
        func createShareController(rootRecord: CKRecord) {
            let sharingController = UICloudSharingController { controller, completion in
                let shareRecord = CKShare(rootRecord: rootRecord)
                
                let container = WorkoutDataStorage.shared.cloudKitten.container
                let operation = CKModifyRecordsOperation(recordsToSave: [rootRecord, shareRecord], recordIDsToDelete: nil)
                operation.perRecordCompletionBlock = { record, error in
                  if let error = error {
                    print("modify record error: \(error.localizedDescription)")
                  }
                }
                operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
                    if let error = error {
                        print("modify records error: \(error.localizedDescription)")
                        completion(nil, nil, error)
                        return
                    }
                    // TODO: somehow save CKShare?
                    print("successfully modified records")
                    let context = self.parent.workout.managedObjectContext!
                    context.performAndWait {
                        for savedRecord in savedRecords ?? [] {
                            try! Workout.updateSystemFields(with: Record(record: savedRecord, databaseScope: .private), context: context)
                        }
                        context.saveOrCrash()
                    }
                    completion(shareRecord, container, nil)
                }
                container.privateCloudDatabase.add(operation)
            }

            sharingController.delegate = self
            if let button = self.button {
                sharingController.popoverPresentationController?.sourceView = button
            }

            UIApplication.shared.windows.first?.rootViewController?.present(sharingController, animated: true)
        }
        
        func editShareController(share: CKShare, container: CKContainer) {
            let sharingController = UICloudSharingController(share: share, container: container)
            sharingController.delegate = self
            
            if let button = self.button {
                sharingController.popoverPresentationController?.sourceView = button
            }

            UIApplication.shared.windows.first?.rootViewController?.present(sharingController, animated: true)
        }
        
        // MARK: UICloudSharingControllerDelegate
        
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("error saving share: \(error.localizedDescription)")
        }
        
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("did save share")
        }
        
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            DispatchQueue.main.async {
                WorkoutDataStorage.shared.pull(from: .private)
            }
//            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                // NOTE: Seems like, if we don't wait a bit, then we get a 'zoneID does not exist' error... (2020-06-09)
//                WorkoutDataStorage.shared.pull(from: .shared)
//            }
        }
        
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Workout (\(parent.workout.start.map { dateFormatter.string(from: $0) } ?? "nil"))"
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environment(\.managedObjectContext, WorkoutDataStorage.shared.persistentContainer.viewContext)
    }
}
