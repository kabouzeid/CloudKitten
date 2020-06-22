//
//  File.swift
//  
//
//  Created by Karim Abou Zeid on 22.06.20.
//

import Foundation

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
