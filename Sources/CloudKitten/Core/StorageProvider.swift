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

@propertyWrapper struct Stored<Value> where Value: Codable {
    let storage: StorageProvider
    let key: String
    let `default`: Value
    
    var wrappedValue: Value {
        get {
            guard let data = try! storage.data(forKey: key) else { return `default` }
            return try! JSONDecoder().decode(Value.self, from: data)
        }
        set {
            let data = try! JSONEncoder().encode(newValue)
            try! storage.store(data: data, forKey: key)
        }
    }
}

extension Stored where Value: ExpressibleByNilLiteral {
    init(storage: StorageProvider, key: String) {
        self.init(storage: storage, key: key, default: nil)
    }
}
