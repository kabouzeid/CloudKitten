//
//  RecordID.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 06.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit

public struct RecordID: Hashable {
    public init(recordID: CKRecord.ID, databaseScope: CKDatabase.Scope) {
        self.recordID = recordID
        self.databaseScope = databaseScope
    }
    
    public let recordID: CKRecord.ID
    public let databaseScope: CKDatabase.Scope
}

// MARK: - Codable
extension RecordID: Codable {
    enum CodingKeys: CodingKey {
        case recordID
        case databaseScope
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(CodableNSCoding<CKRecord.ID>.self, forKey: .recordID).wrapped
        databaseScope = try container.decode(CKDatabase.Scope.self, forKey: .databaseScope)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CodableNSCoding(recordID), forKey: .recordID)
        try container.encode(databaseScope, forKey: .databaseScope)
    }
}
