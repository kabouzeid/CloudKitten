//
//  NSPersistentHistoryChangeToken+Print.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 16.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CoreData

extension NSPersistentHistoryChangeType {
    var name: String {
        switch self {
        case .delete:
            return "delete"
        case .insert:
            return "insert"
        case .update:
            return "update"
        @unknown default:
            return "unknown"
        }
    }
}
