//
//  CodableNSSecureCoding.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 03.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation

struct CodableNSCoding<T>: Hashable where T: NSObject, T: NSSecureCoding {
    let wrapped: T
    
    init(_ wrapped: T) {
        self.wrapped = wrapped
    }
}

extension CodableNSCoding: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: T.self, from: data) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unarchived object is nil")
        }
        wrapped = unarchived
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(try NSKeyedArchiver.archivedData(withRootObject: wrapped, requiringSecureCoding: true))
    }
}
