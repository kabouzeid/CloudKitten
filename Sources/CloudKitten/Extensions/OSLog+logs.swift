//
//  OSLog+logs.swift
//  CloudMagic
//
//  Created by Karim Abou Zeid on 13.04.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import Foundation
import os.log

extension OSLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "-"
    
    static let coreData = OSLog(subsystem: subsystem, category: "Core Data")
    static let sync = OSLog(subsystem: subsystem, category: "Sync")
    static let changeTracker = OSLog(subsystem: subsystem, category: "Change Tracker")
    static let coreDataMonitor = OSLog(subsystem: subsystem, category: "Core Data Monitor")
    static let conflictResolution = OSLog(subsystem: subsystem, category: "Conflict Resolution")
    static let DEBUG = OSLog(subsystem: subsystem, category: "DEBUG")
    
    func trace(type: OSLogType = .debug, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        guard isEnabled(type: type) else { return }
        let file = URL(fileURLWithPath: String(describing: file)).lastPathComponent
        os_log("%{public}@ %{public}@:%ld", log: self, type: type, String(describing: function), file, line)
    }
}
