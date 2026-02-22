//
//  GPSLeecoderApp.swift
//  GPSLeecoder
//
//  Created by Lyon on 2/22/26.
//

import SwiftUI
import UserNotifications

@main
struct GPSLeecoderApp: App {
    init() {
        // Request notification permission for watchdog alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TrackingMapView()
            }
        }
    }
}
