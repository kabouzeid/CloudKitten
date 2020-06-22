//
//  CKRecord+Archiving.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 15.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import CloudKit
import os.log

extension CKRecord {
    convenience init?(archivedData: Data) {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archivedData)
            unarchiver.requiresSecureCoding = true
            self.init(coder: unarchiver)
        } catch {
            os_log("Could not create CKRecord from archived data: %@", log: .sync, type: .error, error.localizedDescription)
            return nil
        }
    }
    
    var encdodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()

        return coder.encodedData
    }
}
