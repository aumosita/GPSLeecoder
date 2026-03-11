//
//  GPSLeecoderApp.swift
//  GPSLeecoder
//
//  Created by Lyon on 2/22/26.
//

import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // iOS가 위치 이벤트로 앱을 재실행한 경우 → 로깅 자동 재개
        if launchOptions?[.location] != nil {
            GPSLogger.shared.resumeLoggingIfNeeded()
        }
        return true
    }
}

@main
struct GPSLeecoderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TrackingMapView()
            }
        }
    }
}
