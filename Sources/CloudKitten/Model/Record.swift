//
//  Record.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 06.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit

public struct Record {
    public init(record: CKRecord, databaseScope: CKDatabase.Scope) {
        self.record = record
        self.databaseScope = databaseScope
    }
    
    public let record: CKRecord
    public let databaseScope: CKDatabase.Scope
}

extension Record {
    public var recordID: RecordID {
        RecordID(recordID: record.recordID, databaseScope: databaseScope)
    }
}
