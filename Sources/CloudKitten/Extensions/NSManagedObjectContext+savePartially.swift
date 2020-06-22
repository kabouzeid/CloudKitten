//
//  NSManagedObjectContext+savePartially.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 22.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CoreData
import os.log

extension NSManagedObjectContext {
    /// Recursively refreshes managed objects with validation errors and to try to save the other managed objects.
    /// - Throws: Rethrows the error of `save()` if the save did not fail because of a validation error.
    /// - Returns: The managed objects that could not be saved due to validation errors.
    func savePartially() throws -> Set<NSManagedObject> {
        try _saveNonAtomic(unsavedObjects: [])
    }
    
    private func _saveNonAtomic(unsavedObjects: Set<NSManagedObject>) throws -> Set<NSManagedObject> {
        do {
            try save()
            return unsavedObjects
        } catch {
            os_log("Saving context failed, trying to save partially", log: .coreData)
            let originalError = error as NSError
            let errors: [NSError]
            if let detailedErrors = originalError.userInfo[NSDetailedErrorsKey] as? [NSError] {
                errors = detailedErrors
            } else {
                errors = [originalError]
            }
            
            var _unsavedObjects = Set<NSManagedObject>()
            for error in errors {
                if let invalidObject = error.userInfo[NSValidationObjectErrorKey] as? NSManagedObject {
                    guard !unsavedObjects.contains(invalidObject) else {
                        // this makes sure that we never get into an infinite loop!
                        // but it should actually never happen, because an object isn't validated again after it has been refreshed
                        preconditionFailure("Validation logic for managed object: \(invalidObject) is flawed. There is a validation error even after refreshing it.")
                    }
                    refresh(invalidObject, mergeChanges: false) // undo the changes
                    _unsavedObjects.insert(invalidObject) // but remember this object, we will try to fetch it again in future
                }
            }
            
            if _unsavedObjects.isEmpty {
                // not (only) a validation error, not our responsibility
                throw originalError
            } else {
                os_log("Refreshed %d invalid objects. Trying to save again", log: .coreData, _unsavedObjects.count)
                return try _saveNonAtomic(unsavedObjects: unsavedObjects.union(_unsavedObjects))
            }
        }
    }
}
