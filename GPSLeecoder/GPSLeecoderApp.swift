//
//  GPSLeecoderApp.swift
//  GPSLeecoder
//
//  Created by Lyon on 2/22/26.
//

import SwiftUI

@main
struct GPSLeecoderApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TrackingMapView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                GPSLogger.shared.applicationDidBecomeActive()
            case .background:
                GPSLogger.shared.applicationDidEnterBackground()
            default:
                break
            }
        }
    }
}
