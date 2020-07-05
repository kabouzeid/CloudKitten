//
//  AppDelegate.swift
//  iOS Example
//
//  Created by Karim Abou Zeid on 21.06.20.
//  Copyright © 2020 Karim Abou Zeid. All rights reserved.
//

import UIKit
import CloudKitten
import Combine
import os.log

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var subscription: AnyCancellable?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        application.registerForRemoteNotifications()
        
        subscription = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .sink { _ in
                // e.g. the user was not signed in to iCloud and is now signed into iCloud
                
                // TODO: detect if the user switched the iCloud Account, in this case delete the local data first
                
                os_log("CKAccountChanged")
                WorkoutDataStorage.shared.cloudKitten.pull(from: .private)
                WorkoutDataStorage.shared.cloudKitten.pull(from: .shared)
                
                WorkoutDataStorage.shared.cloudKitten.push(to: .private)
            }
        
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        os_log("Did register for remote notifications", type: .info)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        os_log("Did fail to register for remote notifications: %@", type: .error, error.localizedDescription)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        os_log("Did receive remote notification userInfo=%@", type: .info, userInfo)
        _ = WorkoutDataStorage.shared.handleNotification(with: userInfo, completionHandler: completionHandler)
    }
}
