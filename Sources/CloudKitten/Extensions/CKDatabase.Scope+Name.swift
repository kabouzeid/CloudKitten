//
//  IntEnum+Names.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 29.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit

extension CKDatabase.Scope {
    var name: String {
        switch self {
        case .private:
            return "private"
        case .public:
            return "public"
        case .shared:
            return "shared"
        @unknown default:
            fatalError("Unknown database scope")
        }
    }
}
