//
//  GPSLeecoderApp.swift
//  GPSLeecoder
//
//  Created by Lyon on 2/22/26.
//

import SwiftUI

@main
struct GPSLeecoderApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TrackingMapView()
            }
        }
    }
}
