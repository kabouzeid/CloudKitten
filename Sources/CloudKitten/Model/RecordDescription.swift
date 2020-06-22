//
//  RecordDescription.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 03.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import CloudKit

struct RecordDescription: Codable, Hashable {
    public init(recordID: RecordID, recordType: CKRecord.RecordType) {
        self.recordID = recordID
        self.recordType = recordType
    }
    
    let recordID: RecordID
    let recordType: CKRecord.RecordType
}

extension RecordDescription {
    init(from record: CKRecord, databaseScope: CKDatabase.Scope) {
        self.recordID = RecordID(recordID: record.recordID, databaseScope: databaseScope)
        self.recordType = record.recordType
    }
    
    init(from record: Record) {
        self.recordID = record.recordID
        self.recordType = record.record.recordType
    }
}
