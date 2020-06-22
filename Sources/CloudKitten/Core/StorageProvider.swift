//
//  StorageProvider.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 03.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation

public protocol StorageProvider {
    func store(data: Data?, forKey key: String) throws
    func data(forKey key: String) throws -> Data?
}
