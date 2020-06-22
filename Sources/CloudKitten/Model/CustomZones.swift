//
//  CustomZones.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 18.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit

struct CustomZones {
    var zoneIDs: Set<CKRecordZone.ID>
}

extension CustomZones {
    static let storageKey = "customZones"
}

extension CustomZones: Codable {
    enum CodingKeys: CodingKey {
        case zoneIDs
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoneIDs = Set(try container.decode(Set<CodableNSCoding<CKRecordZone.ID>>.self, forKey: .zoneIDs).map { $0.wrapped })
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Set(zoneIDs.map { CodableNSCoding($0) }), forKey: .zoneIDs)
    }
}
