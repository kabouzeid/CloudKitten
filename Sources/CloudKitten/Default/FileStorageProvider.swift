//
//  FileStorageProvider.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 03.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import os.log

extension OSLog {
    static let fileManagerStorageProvider = OSLog(subsystem: subsystem, category: "File Manager Storage Provider")
}

public struct FileStorageProvider: StorageProvider {
    var fileManager = FileManager.default
    var baseURL: URL
    
    public init(fileManager: FileManager = .default, baseURL: URL) throws {
        self.fileManager = fileManager
        self.baseURL = baseURL
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        os_log("baseURL=%@", log: .fileManagerStorageProvider, type: .debug, baseURL as NSURL)
    }
    
    // MARK: - StorageProvider
    
    public func store(data: Data?, forKey key: String) throws {
//        os_log("Storing data for key=%@", log: .fileManagerStorageProvider, type: .debug, key)
        let url = self.url(forKey: key)
        if let data = data {
            try data.write(to: url, options: .atomic)
        } else {
            try fileManager.removeItem(at: url)
        }
    }
    
    public func data(forKey key: String) throws -> Data? {
//        os_log("Reading data for key=%@", log: .fileManagerStorageProvider, type: .debug, key)
        let url = self.url(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}

// MARK: - Path/URL
extension FileStorageProvider {
    private func url(forKey key: String) -> URL {
        baseURL.appendingPathComponent(key)
    }
}
